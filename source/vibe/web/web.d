/**
	Implements a declarative framework for building web interfaces.

	This module contains the sister funtionality to the $(D vibe.web.rest)
	module. While the REST interface generator is meant for stateless
	machine-to-machine communication, this module aims at implementing
	user facing web services. Apart from that, both systems use the same
	declarative approach.

	See $(D registerWebInterface) for an overview of how the system works.

	Copyright: © 2013-2015 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.web.web;

public import vibe.internal.meta.funcattr : PrivateAccessProxy, before, after;
public import vibe.web.common;
public import vibe.web.i18n;
public import vibe.web.validation;

import vibe.core.core;
import vibe.http.common;
import vibe.http.router;
import vibe.http.server;

/*
	TODO:
		- conversion errors of path place holder parameters should result in 404
		- support format patterns for redirect()
		- add a way to specify response headers without explicit access to "res"
*/


/**
	Registers a HTTP/web interface based on a class instance.

	Each public method of the given class instance will be mapped to a HTTP
	route. Method parameters will be sourced from either the query string
	or form data of the request, or, if the parameter name has an underscore
	prefixed, from the $(D vibe.http.server.HTTPServerRequest.params) map.

	The latter can be used to inject custom data in various ways. Examples of
	this are placeholders specified in a $D( @path) annotation, values computed
	by a $(D @before) annotation, error information generated by the
	$(D errorDisplay) annotation, or data injected manually in a HTTP method
	handler that processed the request prior to passing it to the generated
	web interface handler routes.

	Methods that return a $(D class) or $(D interface) instance, instead of
	being mapped to a single HTTP route, will be mapped recursively by
	iterating the public routes of the returned instance. This way, complex
	path hierarchies can be mapped to class hierarchies.

	Parameter_conversion_rules:
		For mapping method parameters without a prefixed underscore to
		query/form fields, the following rules are applied:

		$(UL
			$(LI An array of values is mapped to
				$(D &lt;parameter_name&gt;_&lt;index&gt;), where $(D index)
				denotes the zero based index of the array entry. The length
				of the array is determined by searching for the first
				non-existent index in the set of form fields.)
			$(LI $(D Nullable!T) typed parameters, as well as parameters with
				default values, are optional parameters and are allowed to be
				missing in the set of form fields. All other parameter types
				require the corresponding field to be present and will result
				in a runtime error otherwise.)
			$(LI $(D struct) type parameters that don't define a $(D fromString)
				or a $(D fromStringValidate) method will be mapped to one
				form field per struct member with a scheme similar to how
				arrays are treated: $(D &lt;parameter_name&gt;_&lt;member_name&gt;))
			$(LI Boolean parameters will be set to $(D true) if a form field of
				the corresponding name is present and to $(D false) otherwise.
				This is compatible to how check boxes in HTML forms work.)
			$(LI All other types of parameters will be converted from a string
				by using the first available means of the following:
				a static $(D fromStringValidate) method, a static $(D fromString)
				method, using $(D std.conv.to!T).)
			$(LI Any of these rules can be applied recursively, so that it is
				possible to nest arrays and structs appropriately.)
		)

	Special_parameters:
		$(UL
			$(LI A parameter named $(D __error) will be populated automatically
				with error information, when an $(D @errorDisplay) attribute
				is in use.)
			$(LI An $(D InputStream) typed parameter will receive the request
				body as an input stream. Note that this stream may be already
				emptied if the request was subject to certain body parsing
				options. See $(D vibe.http.server.HTTPServerOption).)
			$(LI Parameters of types $(D vibe.http.server.HTTPServerRequest),
				$(D vibe.http.server.HTTPServerResponse),
				$(D vibe.http.common.HTTPRequest) or
				$(D vibe.http.common.HTTPResponse) will receive the
				request/response objects of the invoking request.)
		)


	Supported_attributes:
		The following attributes are supported for annotating methods of the
		registered class:

		$(D @before), $(D @after), $(D @errorDisplay),
		$(D @vibe.web.common.method), $(D @vibe.web.common.path),
		$(D @vibe.web.common.contentType)

	Params:
		router = The HTTP router to register to
		instance = Class instance to use for the web interface mapping
		settings = Optional parameter to customize the mapping process
*/
void registerWebInterface(C : Object, MethodStyle method_style = MethodStyle.lowerUnderscored)(URLRouter router, C instance, WebInterfaceSettings settings = null)
{
	import std.algorithm : endsWith;
	import std.traits;

	if (!settings) settings = new WebInterfaceSettings;

	foreach (M; __traits(allMembers, C)) {
		/*static if (isInstanceOf!(SessionVar, __traits(getMember, instance, M))) {
			__traits(getMember, instance, M).m_getContext = toDelegate({ return s_requestContext; });
		}*/
		static if (!is(typeof(__traits(getMember, Object, M)))) { // exclude Object's default methods and field
			foreach (overload; MemberFunctionsTuple!(C, M)) {
				alias RT = ReturnType!overload;
				enum minfo = extractHTTPMethodAndName!(overload, true)();
				enum url = minfo.hadPathUDA ? minfo.url : adjustMethodStyle(minfo.url, method_style);

				static if (is(RT == class) || is(RT == interface)) {
					// nested API
					static assert(
						ParameterTypeTuple!overload.length == 0,
						"Instances may only be returned from parameter-less functions ("~M~")!"
					);
					auto subsettings = settings.dup;
					subsettings.urlPrefix = concatURL(settings.urlPrefix, url, true);
					registerWebInterface!RT(router, __traits(getMember, instance, M)(), subsettings);
				} else {
					auto fullurl = concatURL(settings.urlPrefix, url);
					router.match(minfo.method, fullurl, (req, res) {
						handleRequest!(M, overload)(req, res, instance, settings);
					});
					if (settings.ignoreTrailingSlash && !fullurl.endsWith("*")) {
						auto m = fullurl.endsWith("/") ? fullurl[0 .. $-1] : fullurl ~ "/";
						router.match(minfo.method, m, (req, res) {
							static if (minfo.method == HTTPMethod.GET) {
								URL redurl = req.fullURL;
								auto redpath = redurl.path;
								redpath.endsWithSlash = !redpath.endsWithSlash;
								redurl.path = redpath;
								res.redirect(redurl);
							} else {
								handleRequest!(M, overload)(req, res, instance, settings);
							}
						});
					}
				}
			}
		}
	}
}


/**
	Gives an overview of the basic features. For more advanced use, see the
	example in the "examples/web/" directory.
*/
unittest {
	import vibe.http.router;
	import vibe.http.server;
	import vibe.web.web;

	class WebService {
		private {
			SessionVar!(string, "login_user") m_loginUser;
		}

		@path("/")
		void getIndex(string _error = null)
		{
			//render!("index.dt", _error);
		}

		// automatically mapped to: POST /login
		@errorDisplay!getIndex
		void postLogin(string username, string password)
		{
			enforceHTTP(username.length > 0, HTTPStatus.forbidden,
				"User name must not be empty.");
			enforceHTTP(password == "secret", HTTPStatus.forbidden,
				"Invalid password.");
			m_loginUser = username;
			redirect("/profile");
		}

		// automatically mapped to: POST /logout
		void postLogout()
		{
			terminateSession();
			redirect("/");
		}

		// automatically mapped to: GET /profile
		void getProfile()
		{
			enforceHTTP(m_loginUser.length > 0, HTTPStatus.forbidden,
				"Must be logged in to access the profile.");
			//render!("profile.dt")
		}
	}

	void run()
	{
		auto router = new URLRouter;
		router.registerWebInterface(new WebService);

		auto settings = new HTTPServerSettings;
		settings.port = 8080;
		listenHTTP(settings, router);
	}
}


/**
	Renders a Diet template file to the current HTTP response.

	This function is equivalent to vibe.http.server.render, but implicitly
	writes the result to the response object of the currently processed
	request.

	Note that this may only be called from a function/method
	registered using registerWebInterface.
*/
template render(string diet_file, ALIASES...) {
	void render(string MODULE = __MODULE__, string FUNCTION = __FUNCTION__)()
	{
		import vibe.web.i18n;
		import vibe.internal.meta.uda : findFirstUDA;
		mixin("static import "~MODULE~";");

		alias PARENT = typeof(__traits(parent, mixin(FUNCTION)).init);
		enum FUNCTRANS = findFirstUDA!(TranslationContextAttribute, mixin(FUNCTION));
		enum PARENTTRANS = findFirstUDA!(TranslationContextAttribute, PARENT);
		static if (FUNCTRANS.found) alias TranslateContext = FUNCTRANS.value.Context;
		else static if (PARENTTRANS.found) alias TranslateContext = PARENTTRANS.value.Context;

		assert(s_requestContext.req !is null, "render() used outside of a web interface request!");
		auto req = s_requestContext.req;

		static if (is(TranslateContext) && TranslateContext.languages.length) {
			static if (TranslateContext.languages.length > 1) {
				switch (s_requestContext.language) {
					default: {
						static string diet_translate__(string key,string context=null) { return tr!(TranslateContext, TranslateContext.languages[0])(key,context); }
						vibe.http.server.render!(diet_file, req, ALIASES, diet_translate__)(s_requestContext.res);
						return;
						}
					foreach (lang; TranslateContext.languages[1 .. $])
						case lang: {
							mixin("struct "~lang~" { static string diet_translate__(string key,string context=null) { return tr!(TranslateContext, lang)(key,context); } void render() { vibe.http.server.render!(diet_file, req, ALIASES, diet_translate__)(s_requestContext.res); } }");
							mixin(lang~" renderctx;");
							renderctx.render();
							return;
							}
				}
			} else {
				static string diet_translate__(string key,string context=null) { return tr!(TranslateContext, TranslateContext.languages[0])(key,context); }
				vibe.http.server.render!(diet_file, req, ALIASES, diet_translate__)(s_requestContext.res);
			}
		} else {
			vibe.http.server.render!(diet_file, req, ALIASES)(s_requestContext.res);
		}
	}
}


/**
	Redirects to the given URL.

	Note that this may only be called from a function/method
	registered using registerWebInterface.
*/
void redirect(string url)
{
	assert(s_requestContext.res !is null, "redirect() used outside of a web interface request!");
	s_requestContext.res.redirect(url);
}


/**
	Terminates the currently active session (if any).

	Note that this may only be called from a function/method
	registered using registerWebInterface.
*/
void terminateSession()
{
	alias ctx = s_requestContext;
	if (ctx.req.session) {
		ctx.res.terminateSession();
		ctx.req.session = Session.init;
	}
}


/**
	Translates a text based on the language of the current web request.

	See_also: $(D vibe.web.i18n.translationContext)
*/
string trWeb(string text, string context = null)
{
	assert(s_requestContext.req !is null, "trWeb() used outside of a web interface request!");
	return s_requestContext.tr(text, context);
}

///
unittest {
	struct TRC {
		import std.typetuple;
		alias languages = TypeTuple!("en_US", "de_DE", "fr_FR");
		//mixin translationModule!"test";
	}

	@translationContext!TRC
	class WebService {
		void index(HTTPServerResponse res)
		{
			res.writeBody(trWeb("This text will be translated!"));
		}
	}
}


/**
	Attribute to customize how errors/exceptions are displayed.

	The first template parameter takes a function that maps an exception and an
	optional field name to a single error type. The result of this function
	will then be passed as the $(D _error) parameter to the method referenced
	by the second template parameter.

	Supported types for the $(D _error) parameter are $(D bool), $(D string),
	$(D Exception), or a user defined $(D struct). The $(D field) member, if
	present, will be set to null if the exception was thrown after the field
	validation has finished.
*/
@property errorDisplay(alias DISPLAY_METHOD)()
{
	return ErrorDisplayAttribute!DISPLAY_METHOD.init;
}

/// Shows the basic error message display.
unittest {
	void getForm(string _error = null)
	{
		//render!("form.dt", _error);
	}

	@errorDisplay!getForm
	void postForm(string name)
	{
		if (name.length == 0)
			throw new Exception("Name must not be empty");
		redirect("/");
	}
}

/// Advanced error display including the offending form field.
unittest {
	struct FormError {
		// receives the original error message
		string error;
		// receives the name of the field that caused the error, if applicable
		string field;
	}

	void getForm(FormError _error = FormError.init)
	{
		//render!("form.dt", _error);
	}

	// throws an error if the submitted form value is not a valid integer
	@errorDisplay!getForm
	void postForm(int ingeter)
	{
		redirect("/");
	}
}


/**
	Encapsulates settings used to customize the generated web interface.
*/
class WebInterfaceSettings {
	string urlPrefix = "/";
	bool ignoreTrailingSlash = true;

	@property WebInterfaceSettings dup() const {
		auto ret = new WebInterfaceSettings;
		ret.urlPrefix = this.urlPrefix;
		return ret;
	}
}


/**
	Maps a web interface member variable to a session field.

	Setting a SessionVar variable will implicitly start a session, if none
	has been started yet. The content of the variable will be stored in
	the session store and is automatically serialized and deserialized.

	Note that variables of type SessionVar must only be used from within
	handler functions of a class that was registered using
	$(D registerWebInterface). Also note that two different session
	variables with the same $(D name) parameter will access the same
	underlying data.
*/
struct SessionVar(T, string name) {
	private {
		T m_initValue;
	}

	/** Initializes a session var with a constant value.
	*/
	this(T init_val) { m_initValue = init_val; }
	///
	unittest {
		class MyService {
			SessionVar!(int, "someInt") m_someInt = 42;

			void index() {
				assert(m_someInt == 42);
			}
		}
	}

	/** Accesses the current value of the session variable.

		Any access will automatically start a new session and set the
		initializer value, if necessary.
	*/
	@property const(T) value()
	{
		assert(s_requestContext.req !is null, "SessionVar used outside of a web interface request!");
		alias ctx = s_requestContext;
		if (!ctx.req.session) ctx.req.session = ctx.res.startSession();

		if (ctx.req.session.isKeySet(name))
			return ctx.req.session.get!T(name);

		ctx.req.session.set!T(name, m_initValue);
		return m_initValue;
	}
	/// ditto
	@property void value(T new_value)
	{
		assert(s_requestContext.req !is null, "SessionVar used outside of a web interface request!");
		alias ctx = s_requestContext;
		if (!ctx.req.session) ctx.req.session = ctx.res.startSession();
		ctx.req.session.set(name, new_value);
	}

	void opAssign(T new_value) { this.value = new_value; }

	alias value this;
}


struct ErrorDisplayAttribute(alias DISPLAY_METHOD) {
	import std.traits : ParameterTypeTuple, ParameterIdentifierTuple;

	alias displayMethod = DISPLAY_METHOD;
	enum displayMethodName = __traits(identifier, DISPLAY_METHOD);

	private template GetErrorParamType(size_t idx) {
		static if (idx >= ParameterIdentifierTuple!DISPLAY_METHOD.length)
			static assert(false, "Error display method "~displayMethodName~" is missing the _error parameter.");
		else static if (ParameterIdentifierTuple!DISPLAY_METHOD[idx] == "_error")
			alias GetErrorParamType = ParameterTypeTuple!DISPLAY_METHOD[idx];
		else alias GetErrorParamType = GetErrorParamType!(idx+1);
	}

	alias ErrorParamType = GetErrorParamType!0;

	ErrorParamType getError(Exception ex, string field)
	{
		static if (is(ErrorParamType == bool)) return true;
		else static if (is(ErrorParamType == string)) return ex.msg;
		else static if (is(ErrorParamType == Exception)) return ex;
		else static if (is(typeof(ErrorParamType(ex, field)))) return ErrorParamType(ex, field);
		else static if (is(typeof(ErrorParamType(ex.msg, field)))) return ErrorParamType(ex.msg, field);
		else static if (is(typeof(ErrorParamType(ex.msg)))) return ErrorParamType(ex.msg);
		else static assert(false, "Error parameter type %s does not have the required constructor.");
	}
}


private {
	TaskLocal!RequestContext s_requestContext;
}

private struct RequestContext {
	HTTPServerRequest req;
	HTTPServerResponse res;
	string language;
	string function(string, string) tr;
}

private void handleRequest(string M, alias overload, C, ERROR...)(HTTPServerRequest req, HTTPServerResponse res, C instance, WebInterfaceSettings settings, ERROR error)
	if (ERROR.length <= 1)
{
	import std.algorithm : countUntil, startsWith;
	import std.traits;
	import std.typetuple : Filter;
	import vibe.data.json;
	import vibe.internal.meta.funcattr;
	import vibe.internal.meta.uda : findFirstUDA;

	alias RET = ReturnType!overload;
	alias PARAMS = ParameterTypeTuple!overload;
	alias default_values = ParameterDefaultValueTuple!overload;
	enum param_names = [ParameterIdentifierTuple!overload];
	enum erruda = findFirstUDA!(ErrorDisplayAttribute, overload);

	s_requestContext = createRequestContext!overload(req, res);

	// collect all parameter values
	PARAMS params = void;
	foreach (i, PT; PARAMS) {
		try {
			static if (IsAttributedParameter!(overload, param_names[i])) {
				params[i].setVoid(computeAttributedParameterCtx!(overload, param_names[i])(instance, req, res));
				if (res.headerWritten) return;
			}
			else static if (param_names[i] == "_error") {
				static if (ERROR.length == 1)
					params[i].setVoid(error[0]);
				else static if (!is(default_values[i] == void))
					params[i].setVoid(default_values[i]);
				else
					params[i] = typeof(params[i]).init;
			}
			else static if (is(PT == InputStream)) params[i] = req.bodyReader;
			else static if (is(PT == HTTPServerRequest) || is(PT == HTTPRequest)) params[i] = req;
			else static if (is(PT == HTTPServerResponse) || is(PT == HTTPResponse)) params[i] = res;
			else static if (param_names[i].startsWith("_")) {
				if (auto pv = param_names[i][1 .. $] in req.params) params[i].setVoid((*pv).webConvTo!PT);
				else static if (!is(default_values[i] == void)) params[i].setVoid(default_values[i]);
				else static if (!isNullable!PT) enforceHTTP(false, HTTPStatus.badRequest, "Missing request parameter for "~param_names[i]);
			} else static if (is(PT == bool)) {
				params[i] = param_names[i] in req.form || param_names[i] in req.query;
			} else {
				static if (!is(default_values[i] == void)) {
					if (!readFormParamRec(req, params[i], param_names[i], false))
						params[i].setVoid(default_values[i]);
				} else {
					readFormParamRec(req, params[i], param_names[i], true);
				}
			}
		} catch (Exception ex) {
			static if (erruda.found && ERROR.length == 0) {
				auto err = erruda.value.getError(ex, param_names[i]);
				handleRequest!(erruda.value.displayMethodName, erruda.value.displayMethod)(req, res, instance, settings, err);
				return;
			} else {
				auto hex = new HTTPStatusException(HTTPStatus.badRequest, "Error handling parameter "~param_names[i]~": "~ex.msg);
				hex.debugMessage = ex.toString().sanitize;
				throw hex;
			}
		}
	}

	// validate all confirmation parameters
	foreach (i, PT; PARAMS) {
		static if (isNullable!PT)
			alias ParamBaseType = typeof(PT.init.get());
		else alias ParamBaseType = PT;

		static if (isInstanceOf!(Confirm, ParamBaseType)) {
			enum pidx = param_names.countUntil(PT.confirmedParameter);
			static assert(pidx >= 0, "Unknown confirmation parameter reference \""~PT.confirmedParameter~"\".");
			static assert(pidx != i, "Confirmation parameter \""~PT.confirmedParameter~"\" may not reference itself.");

			bool matched;
			static if (isNullable!PT && isNullable!(PARAMS[pidx])) {
				matched = (params[pidx].isNull() && params[i].isNull()) ||
					(!params[pidx].isNull() && !params[i].isNull() && params[pidx] == params[i]);
			} else {
				static assert(!isNullable!PT && !isNullable!(PARAMS[pidx]),
					"Either both or none of the confirmation and original fields must be nullable.");
				matched = params[pidx] == params[i];
			}

			if (!matched) {
				auto ex = new Exception("Comfirmation field mismatch.");
				static if (erruda.found && ERROR.length == 0) {
					auto err = erruda.value.getError(ex, param_names[i]);
					handleRequest!(erruda.value.displayMethodName, erruda.value.displayMethod)(req, res, instance, settings, err);
					return;
				} else {
					throw new HTTPStatusException(HTTPStatus.badRequest, ex.msg);
				}
			}
		}
	}

	// execute the method and write the result
	try {
		import vibe.internal.meta.funcattr;

		static if (is(RET == void)) {
			__traits(getMember, instance, M)(params);
		} else {
			auto ret = __traits(getMember, instance, M)(params);
			ret = evaluateOutputModifiers!overload(ret);

			static if (is(RET : Json)) {
				res.writeJsonBody(ret);
			} else static if (is(RET : InputStream) || is(RET : const ubyte[])) {
				enum type = findFirstUDA!(ContentTypeAttribute, overload);
				static if (type.found) {
					res.writeBody(ret, type.value);
				} else {
					res.writeBody(ret);
				}
			} else {
				static assert(is(RET == void), M~": Only InputStream, Json and void are supported as return types for route methods.");
			}
		}
	} catch (Exception ex) {
		import vibe.core.log;
		logDebug("Web handler %s has thrown: %s", M, ex);
		static if (erruda.found && ERROR.length == 0) {
			auto err = erruda.value.getError(ex, null);
			handleRequest!(erruda.value.displayMethodName, erruda.value.displayMethod)(req, res, instance, settings, err);
		} else throw ex;
	}
}


private RequestContext createRequestContext(alias handler)(HTTPServerRequest req, HTTPServerResponse res)
{
	RequestContext ret;
	ret.req = req;
	ret.res = res;
	ret.language = determineLanguage!handler(req);

	import vibe.web.i18n;
	import vibe.internal.meta.uda : findFirstUDA;

	alias PARENT = typeof(__traits(parent, handler).init);
	enum FUNCTRANS = findFirstUDA!(TranslationContextAttribute, handler);
	enum PARENTTRANS = findFirstUDA!(TranslationContextAttribute, PARENT);
	static if (FUNCTRANS.found) alias TranslateContext = FUNCTRANS.value.Context;
	else static if (PARENTTRANS.found) alias TranslateContext = PARENTTRANS.value.Context;

	static if (is(TranslateContext) && TranslateContext.languages.length) {
		static if (TranslateContext.languages.length > 1) {
			switch (ret.language) {
				default: ret.tr = &tr!(TranslateContext, TranslateContext.languages[0]); break;
				foreach (lang; TranslateContext.languages[1 .. $]) {
					case lang:
						ret.tr = &tr!(TranslateContext, lang);
						break;
				}
			}
		} else ret.tr = &tr!(TranslateContext, TranslateContext.languages[0]);
	} else ret.tr = (t,c) => t;

	return ret;
}
