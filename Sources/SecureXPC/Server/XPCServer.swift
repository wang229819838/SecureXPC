//
//  XPCServer.swift
//  SecureXPC
//
//  Created by Josh Kaplan on 2021-10-09
//

import Foundation

/// An XPC server to receive requests from and send responses to an ``XPCClient``.
///
/// ### Retrieving a Server
/// Typically this is as easy as:
/// ```swift
/// let server = try XPCServer.forThisProcess()
/// ```
///
/// This will always work for any
/// [XPC service](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html).
/// XPC services are helper tools which ship as part of your app and only your app can communicate with.
///
/// In most cases helper tools installed with
/// [`SMJobBless`](https://developer.apple.com/documentation/servicemanagement/1431078-smjobbless) and login items installed with
/// [`SMLoginItemSetEnabled`](https://developer.apple.com/documentation/servicemanagement/1501557-smloginitemsetenabled) can
/// also be retrieved in the same way. See ``ProcessType/blessedHelperTool`` and ``ProcessType/loginItem`` for details.
///
/// For Launch Agents, Launch Daemons, and any other types of services an `XPCServer` can be retrieved by explicitly creating a
/// ``ProcessType/machService(name:clientRequirements:)`` instance.
///
/// #### Anonymous servers
/// An anonymous server can be created by any macOS program. Use cases for making one include:
///  - Allowing two processes which are not XPC services to communicate over XPC with each other. This is done by having one of those processes make an
///    anonymous server and send its ``XPCServer/endpoint`` to an XPC Mach service. The other process then needs to retrieve that endpoint from the XPC
///    Mach service and create a client using ``XPCClient/forEndpoint(_:)``.
///  - Testing code that would otherwise run as part of an XPC Mach service without needing to install a helper tool. However, note that this code won't run as root.
///
/// ### Registering & Handling Routes
/// Once a server instance has been retrieved, one or more routes should be registered with it. This is done by calling one of the `registerRoute` functions and
/// providing a route and a compatible closure or function. For example:
/// ```swift
///     ...
///     let updateRoute = XPCRoute.named("config", "update")
///                               .withMessageType(Config.self)
///                               .withReplyType(Config.self)
///     server.registerRoute(updateRoute, handler: updateConfig)
/// }
///
/// private func updateConfig(_ config: Config) throws -> Config {
///     <# implementation here #>
/// }
/// ```
///
/// Routes with sequential reply types can respond to the client arbitrarily many times and therefore must explicitly provide responses to a
/// ``SequentialResultProvider``:
/// ```swift
///     ...
///     let changesRoute = XPCRoute.named("config", "changes")
///                                .withSequentialReplyType(Config.self)
///     server.registerRoute(changesRoute, handler: configChanges)
/// }
///
/// private func configChanges(provider: SequentialResultProvider<Config>) {
///     <# implementation here #>
/// }
/// ```
///
/// On macOS 10.15 and later async functions and closures can also be registered as the handler for a route. For command line tools, such as the helper tools
/// installed with `SMJobBless`, async functions and closures are only supported on macOS 12 and later. This is an
/// [Apple limitation](https://developer.apple.com/forums/thread/701969) unrelated to SecureXPC.
///
/// ### Starting a Server
/// Once all of the routes are registered, the server must be told to start processing requests. In most cases this should be done with:
/// ```swift
/// server.startAndBlock()
/// ```
///
/// Server instances which conform to ``XPCNonBlockingServer`` can also be started in a non-blocking manner:
/// ```swift
/// server.start()
/// ```
///
/// ### Requirements Checking
/// On macOS 11 and later, requirement checking uses publicly documented APIs. On older versions of macOS, the private undocumented API
/// `void xpc_connection_get_audit_token(xpc_connection_t, audit_token_t *)` will be used.  When requests are not accepted, if an error
/// handler has been set then it is called with ``XPCError/insecure``.
///
/// ## Topics
/// ### Retrieving a Server
/// - ``forThisProcess(ofType:)``
/// - ``ProcessType``
/// - ``makeAnonymous()``
/// - ``makeAnonymous(clientRequirements:)``
/// ### Registering Async Routes
/// - ``registerRoute(_:handler:)-6htah``
/// - ``registerRoute(_:handler:)-g7ww``
/// - ``registerRoute(_:handler:)-rw2w``
/// - ``registerRoute(_:handler:)-2vk6u``
/// - ``registerRoute(_:handler:)-7r1hv``
/// - ``registerRoute(_:handler:)-7ngxn``
/// ### Registering Synchronous Routes
/// - ``registerRoute(_:handler:)-4ttqe``
/// - ``registerRoute(_:handler:)-9a0x9``
/// - ``registerRoute(_:handler:)-4fxv0``
/// - ``registerRoute(_:handler:)-1jw9d``
/// - ``registerRoute(_:handler:)-6sxby``
/// - ``registerRoute(_:handler:)-qcox``
/// ### Configuring a Server
/// - ``handlerQueue``
/// - ``setErrorHandler(_:)-lex4``
/// - ``setErrorHandler(_:)-1r3up``
/// ### Starting a Server
/// - ``startAndBlock()``
/// - ``XPCNonBlockingServer/start()``
/// ### Server State
/// - ``connectionDescriptor``
/// - ``endpoint``
public class XPCServer {
    
    /// The queue used to run synchronous handlers associated with registered routes.
    ///
    /// By default this is the
    /// [global concurrent queue](https://developer.apple.com/documentation/dispatch/dispatchqueue/2300077-global).
    ///
    /// Requests will be dispatched to this queue in the order in which they are received by the server. However, even if this is set to a serial `DispatchQueue`
    /// that does not guarantee the order will match `send` or `sendMessage` calls made by an ``XPCClient`` due to their asynchronous nature. If a need
    /// exists for the server to receive requests in a specific order, the caller must wait until a `send` or `sendMessage` call has completed before calling the
    /// next one.
    ///
    /// >Note: `async` handlers for registered routes do not make use of this queue and may always be run concurrently.
    public var handlerQueue = DispatchQueue.global()
    
    /// Used to determine whether an incoming XPC message from a client should be processed and handed off to a registered route.
    internal let messageAcceptor: MessageAcceptor
    
    internal init(messageAcceptor: MessageAcceptor) {
        self.messageAcceptor = messageAcceptor
    }
    
    // MARK: Route registration
    
    private var routes = [XPCRoute : XPCHandler]()
        
    /// Internal function that actually registers the route and enforces that a route is only ever registered once.
    ///
    /// All of the public functions exist to satisfy type constraints.
    private func registerRoute(_ route: XPCRoute, handler: XPCHandler) {
        if let _ = self.routes.updateValue(handler, forKey: route) {
            fatalError("Route \(route.pathComponents) is already registered")
        }
    }
        
    /// Registers a route for a request without a message that does not receive a reply.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has no message and can't receive a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute(_ route: XPCRouteWithoutMessageWithoutReply,
                              handler: @escaping () throws -> Void) {
        self.registerRoute(route.route, handler: ConstrainedXPCHandlerWithoutMessageWithoutReplySync(handler: handler))
    }
    
    /// Registers a route for a request without a message that does not receive a reply.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has no message and can't receive a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    @available(macOS 10.15.0, *)
    public func registerRoute(_ route: XPCRouteWithoutMessageWithoutReply,
                              handler: @escaping () async throws -> Void) {
        self.registerRoute(route.route, handler: ConstrainedXPCHandlerWithoutMessageWithoutReplyAsync(handler: handler))
    }
    
    /// Registers a route for a request with a message that does not receive a reply.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has a message and can't receive a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute<M: Decodable>(_ route: XPCRouteWithMessageWithoutReply<M>,
                                            handler: @escaping (M) throws -> Void) {
        self.registerRoute(route.route, handler: ConstrainedXPCHandlerWithMessageWithoutReplySync(handler: handler))
    }
    
    /// Registers a route for a request with a message that does not receive a reply.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has a message and can't receive a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    @available(macOS 10.15.0, *)
    public func registerRoute<M: Decodable>(_ route: XPCRouteWithMessageWithoutReply<M>,
                                            handler: @escaping (M) async throws -> Void) {
        self.registerRoute(route.route, handler: ConstrainedXPCHandlerWithMessageWithoutReplyAsync(handler: handler))
    }
    
    /// Registers a route for a request without a message that receives a reply.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has no message and expects a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute<R: Decodable>(_ route: XPCRouteWithoutMessageWithReply<R>,
                                            handler: @escaping () throws -> R) {
        self.registerRoute(route.route, handler: ConstrainedXPCHandlerWithoutMessageWithReplySync(handler: handler))
    }
    
    /// Registers a route for a request without a message that receives a reply.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has no message and expects a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    @available(macOS 10.15.0, *)
    public func registerRoute<R: Decodable>(_ route: XPCRouteWithoutMessageWithReply<R>,
                                            handler: @escaping () async throws -> R) {
        self.registerRoute(route.route, handler: ConstrainedXPCHandlerWithoutMessageWithReplyAsync(handler: handler))
    }
    
    /// Registers a route for a request with a message that receives a reply.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has a message and expects a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute<M: Decodable, R: Encodable>(_ route: XPCRouteWithMessageWithReply<M, R>,
                                                          handler: @escaping (M) throws -> R) {
        self.registerRoute(route.route, handler: ConstrainedXPCHandlerWithMessageWithReplySync(handler: handler))
    }
    
    /// Registers a route for a request with a message that receives a reply.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has a message and expects a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    @available(macOS 10.15.0, *)
    public func registerRoute<M: Decodable, R: Encodable>(_ route: XPCRouteWithMessageWithReply<M, R>,
                                                          handler: @escaping (M) async throws -> R) {
        self.registerRoute(route.route, handler: ConstrainedXPCHandlerWithMessageWithReplyAsync(handler: handler))
    }
    
    /// Registers a route for a request without a message that can receive sequential responses.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has no message and can receive zero or more sequential replies.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute<S: Encodable>(
        _ route: XPCRouteWithoutMessageWithSequentialReply<S>,
        handler: @escaping (SequentialResultProvider<S>) -> Void
    ) {
        let constrainedHandler = ConstrainedXPCHandlerWithoutMessageWithSequentialReplySync(handler: handler)
        self.registerRoute(route.route, handler: constrainedHandler)
    }
    
    /// Registers a route for a request without a message that can receive sequential replies.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has no message and can receive zero or more sequential replies.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    @available(macOS 10.15.0, *)
    public func registerRoute<S: Encodable>(
        _ route: XPCRouteWithoutMessageWithSequentialReply<S>,
        handler: @escaping (SequentialResultProvider<S>) async -> Void
    ) {
        let constrainedHandler = ConstrainedXPCHandlerWithoutMessageWithSequentialReplyAsync(handler: handler)
        self.registerRoute(route.route, handler: constrainedHandler)
    }
    
    /// Registers a route for a request with a message that can receive sequential replies.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has a message and can receive zero or more sequential responses.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute<M: Decodable, S: Encodable>(
        _ route: XPCRouteWithMessageWithSequentialReply<M, S>,
        handler: @escaping (M, SequentialResultProvider<S>) -> Void
    ) {
        let constrainedHandler = ConstrainedXPCHandlerWithMessageWithSequentialReplySync(handler: handler)
        self.registerRoute(route.route, handler: constrainedHandler)
    }
    
    /// Registers a route for a request with a message that can receive sequential replies.
    ///
    /// > Important: Routes can only be registered with a handler once; it is a programming error to provide a route which has already been registered.
    ///
    /// - Parameters:
    ///   - route: A route that has a message and can receive zero or more sequential responses.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    @available(macOS 10.15.0, *)
    public func registerRoute<M: Decodable, S: Encodable>(
        _ route: XPCRouteWithMessageWithSequentialReply<M, S>,
        handler: @escaping (M, SequentialResultProvider<S>) async -> Void
    ) {
        let constrainedHandler = ConstrainedXPCHandlerWithMessageWithSequentialReplyAsync(handler: handler)
        self.registerRoute(route.route, handler: constrainedHandler)
    }
    
    internal func startClientConnection(_ connection: xpc_connection_t) {
        // Listen for events (messages or errors) coming from this connection
        xpc_connection_set_event_handler(connection, { event in
            self.handleEvent(connection: connection, event: event)
        })
        xpc_connection_resume(connection)
    }
    
    private func handleEvent(connection: xpc_connection_t, event: xpc_object_t) {
        // Only dictionary types and errors are expected. If it's not a dictionary and not an XPC C API error, then that
        // itself is an error and `XPCError.fromXPCObject` will properly handle this case.
        // Note that we're intentionally not checking for message acceptance as errors generated by libxpc can fail to
        // meet the acceptor's criteria because they're not coming from the client.
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
            self.errorHandler.handle(XPCError.fromXPCObject(event))
            return
        }
        
        guard self.messageAcceptor.acceptMessage(connection: connection, message: event) else {
            self.errorHandler.handle(.insecure)
            return
        }
        self.handleMessage(connection: connection, message: event)
    }
    
    private func handleMessage(connection: xpc_connection_t, message: xpc_object_t) {
        let request: Request
        do {
            request = try Request(dictionary: message)
        } catch {
            var reply = xpc_dictionary_create_reply(message)
            self.handleError(error, request: nil, connection: connection, reply: &reply)
            return
        }
        
        guard let handler = self.routes[request.route] else {
            let error = XPCError.routeNotRegistered(routeName: request.route.pathComponents)
            var reply = xpc_dictionary_create_reply(message)
            self.handleError(error, request: request, connection: connection, reply: &reply)
            return
        }
        
        if let handler = handler as? XPCHandlerSync {
            // The handler queue must be used to run sync handlers. The underlying XPC framework always delivers events
            // serially for the same connection (client in SecureXPC parlance) even if a target queue applied to the
            // connection is concurrent. From xpc_connection_set_target_queue:
            //
            //    If the target queue is a concurrent queue, then XPC still guarantees that there will never be more
            //    than one invocation of the connection's event handler block executing concurrently.
            //
            // This is *not* the behavior we want for XPCServer, which is intended to operate more like a web server
            // that largely abstracts away the concept of a client at all. As such, by default the target queue is
            // concurrent. (Although if an API user sets the target queue to be serial that's supported too.)
            self.handlerQueue.async {
                XPCRequestContext.setForCurrentThread(connection: connection, message: message) {
                    var reply = handler.shouldCreateReply ? xpc_dictionary_create_reply(message) : nil
                    do {
                        try handler.handle(request: request, server: self, connection: connection, reply: &reply)
                        try self.maybeSendReply(&reply, request: request, connection: connection)
                    } catch {
                        var reply = handler.shouldCreateReply ? reply : xpc_dictionary_create_reply(message)
                        self.handleError(error, request: request, connection: connection, reply: &reply)
                    }
                }
            }
        } else if #available(macOS 10.15.0, *), let handler = handler as? XPCHandlerAsync {
            XPCRequestContext.setForTask(connection: connection, message: message) {
                // Creating a task allows it to begin running immediately, operating similar to a concurrent
                // DispatchQueue. However, the difference is there's no built in support to enforce serial execution.
                // From Task:
                //
                //   When you create an instance of Task, you provide a closure that contains the work for that task to
                //   perform. Tasks can start running immediately after creation; you don’t explicitly start or schedule
                //   them.
                //
                // Note: An implementation was created, but never merged, that enabled serial execution of Tasks by
                // manually managing the queue. The additional complexity was of little value as it doesn't result in
                // consistent ordering of received events due to the asynchronous behavior of how they're sent by the
                // XPCClient. If an API user wants consistent ordering, that needs to be done at the application layer.
                Task {
                    var reply = handler.shouldCreateReply ? xpc_dictionary_create_reply(message) : nil
                    do {
                        try await handler.handle(request: request, server: self, connection: connection, reply: &reply)
                        try self.maybeSendReply(&reply, request: request, connection: connection)
                    } catch {
                        var reply = handler.shouldCreateReply ? reply : xpc_dictionary_create_reply(message)
                        self.handleError(error, request: request, connection: connection, reply: &reply)
                    }
                }
            }
        } else {
            fatalError("Non-sync handler for route \(request.route.pathComponents) was found, but only sync routes " +
                       "should be registrable on this OS version. Handler: \(handler)")
        }
    }
    
    // MARK: Error handling
    
    var errorHandler = ErrorHandler.none
    
    /// Sets a handler to synchronously receive any errors encountered.
    ///
    /// This will replace any previously set error handler, including an asynchronous one.
    public func setErrorHandler(_ handler: @escaping (XPCError) -> Void) {
        self.errorHandler = .sync(handler)
    }
    
    /// Sets a handler to asynchronously receive any errors encountered.
    ///
    /// This will replace any previously set error handler, including a synchronous one.
    @available(macOS 10.15.0, *)
    public func setErrorHandler(_ handler: @escaping (XPCError) async -> Void) {
        self.errorHandler = .async(handler)
    }
    
    private func handleError(
        _ error: Error,
        request: Request?,
        connection: xpc_connection_t,
        reply: inout xpc_object_t?
    ) {
        let error = XPCError.asXPCError(error: error)
        self.errorHandler.handle(error)
        
        // If it's possible to reply, then send the error back to the client
        if var nonNilReply = reply {
            do {
                try Response.encodeError(error, intoReply: &nonNilReply)
                try maybeSendReply(&reply, request: request, connection: connection)
            } catch {
                // If these actions fail, then there's no way to proceed
            }
        }
    }
    
    /// Tries to send a reply if the `reply` and `request` objects aren't nil.
    private func maybeSendReply(_ reply: inout xpc_object_t?, request: Request?, connection: xpc_connection_t) throws {
        if var reply = reply, let request = request {
            try Response.encodeRequestID(request.requestID, intoReply: &reply)
            xpc_connection_send_message(connection, reply)
        }
    }

	// MARK: Abstract methods & properties
    
    /// Begins processing requests received by this XPC server and never returns.
    ///
    /// If this server is for an XPC service, how the server will run is determined by the info property list's
    /// [`RunLoopType`](https://developer.apple.com/documentation/bundleresources/information_property_list/xpcservice/runlooptype?changes=l_3).
    /// If no value is specified, `dispatch_main` is the default. If `dispatch_main` is specified or defaulted to, it is a programming error to call this function
    /// from any thread besides the main thread.
    ///
    /// If this server is for a Mach service or is an anonymous server, it is always a programming error to call this function from any thread besides the main thread.
    public func startAndBlock() -> Never {
        fatalError("Abstract Method")
    }
    
    /// The type of connections serviced by this server.
    public var connectionDescriptor: XPCConnectionDescriptor {
        fatalError("Abstract Property")
    }
    
    /// Retrieve an endpoint for this XPC server and then use ``XPCClient/forEndpoint(_:)`` to create a client.
    ///
    /// Endpoints can be sent across an XPC connection.
    ///
    /// XPC services do not have endpoints, while XPC Mach services and anonymous servers both do.
    public var endpoint: XPCServerEndpoint? {
        fatalError("Abstract Property")
    }
}

// MARK: public server protocols

/// An ``XPCServer`` which can be started in a non-blocking manner.
///
/// > Warning: Do not implement this protocol. Additions made to this protocol will not be considered a breaking change for SemVer purposes.
public protocol XPCNonBlockingServer {
    /// Begins processing requests received by this XPC server.
    func start()
}

// MARK: public factories

// Contains all of the `static` code that provides the entry points to retrieving an `XPCServer` instance.
extension XPCServer {
    /// Creates a new anonymous server that accepts requests from the same process it's running in.
    ///
    /// Only a client created from an anonymous server's endpoint can communicate with that server. Do this by retrieving the server's
    /// ``XPCServer/endpoint`` and then creating a client with it:
    /// ```swift
    /// let server = XPCServer.makeAnonymous()
    /// let client = XPCClient.fromEndpoint(server.endpoint)
    /// ```
    ///
    /// > Important: No requests will be processed until ``XPCNonBlockingServer/start()`` or ``startAndBlock()`` is called.
    ///
    /// > Note: If you need this server to be communicated with by clients running in a different process, use ``makeAnonymous(clientRequirements:)``
    /// instead.
    public static func makeAnonymous() -> XPCServer & XPCNonBlockingServer {
        XPCAnonymousServer(messageAcceptor: SameProcessMessageAcceptor())
    }

    /// Creates a new anonymous server that accepts requests from clients which meet the security requirements.
    ///
    /// Only a client created from an anonymous server's endpoint can communicate with that server. Retrieve the ``XPCServer/endpoint`` and send it
    /// across an existing XPC connection. Because other processes on the system can talk to an anonymous server, when making a server it is required that you
    /// specifiy the
    /// [requirements](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)
    /// of any connecting clients:
    /// ```swift
    /// let reqString = "identifier \"com.example.AuthorizedClient\" and certificate leaf[subject.OU] = \"4L0ZG128MM\""
    /// var requirement: SecRequirement?
    /// if SecRequirementCreateWithString(reqString as CFString,
    ///                                   SecCSFlags(),
    ///                                   &requirement) == errSecSuccess,
    ///    let requirement = requirement {
    ///     let server = XPCServer.makeAnonymous(clientRequirements: [requirement])
    ///
    ///     <# configure and start server #>
    /// }
    /// ```
    ///
    /// > Important: No requests will be processed until ``XPCNonBlockingServer/start()`` or ``startAndBlock()`` is called.
    ///
    /// > Note: If you only need this server to be communicated with by clients running in the same process, use ``makeAnonymous()`` instead.
    ///
    /// - Parameters:
    ///   - clientRequirements: If a request is received from a client, it will only be processed if it meets one (or more) of these requirements.
    public static func makeAnonymous(clientRequirements: [SecRequirement]) -> XPCServer & XPCNonBlockingServer {
        XPCAnonymousServer(messageAcceptor: SecRequirementsMessageAcceptor(clientRequirements))
    }
    
    /// The type of process an ``XPCServer`` should be retrieved for.
    public enum ProcessType {
        /// Auto-detects what type of server to create for this process.
        ///
        /// Auto-detection currently supports:
        /// - ``xpcService``
        /// - ``blessedHelperTool``
        /// - ``loginItem``
        ///
        /// For any other type such as Launch Agent or Launch Daemon, ``machService(name:clientRequirements:)`` must be used to explicitly
        /// specify this service's name and client requirements.
        case autoDetect
        /// A process that is an [XPC service](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)
        case xpcService
        /// A process that is a helper tool installed with
        /// [`SMJobBless`](https://developer.apple.com/documentation/servicemanagement/1431078-smjobbless).
        ///
        /// For a server to be automatically created for this process the following requirements must be met:
        ///   - The launchd property list embedded in this helper tool must have exactly one entry for its `MachServices` dictionary
        ///   - The info property list embedded in this helper tool must have at least one element in its
        ///   [`SMAuthorizedClients`](https://developer.apple.com/documentation/bundleresources/information_property_list/smauthorizedclients)
        ///   array
        ///   - Every element in the `SMAuthorizedClients` array must be a valid security requirement
        ///     - To be valid, it must be creatable by
        ///     [`SecRequirementCreateWithString`](https://developer.apple.com/documentation/security/1394522-secrequirementcreatewithstring)
        ///
        /// The returned server will accept incoming requests from clients that meet _any_ of the `SMAuthorizedClients` requirements.
        ///
        /// If this process does not meet these requirements or you would like to have different acceptance criteria for incoming requests then a
        /// ``machService(name:clientRequirements:)`` may be used instead to explicitly specify this service's name and client requirements.
        case blessedHelperTool
        
        /// A process that is a login item enabled with
        /// [`SMLoginItemSetEnabled`](https://developer.apple.com/documentation/servicemanagement/1501557-smloginitemsetenabled).
        ///
        /// For a server to be automatically created for this process the following requirements must be met:
        ///   - This bundle for this process must have a team identifier
        ///   - If this is a sandboxed login item, the
        ///     [`com.apple.security.application-groups`](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_application-groups)
        ///     entitlement must be present and one of the application groups must have the same team identifier as this login item
        ///
        /// The returned server will accept incoming requests from the main app or helper tools contained within the main app bundle. Additionally they must have
        /// the same team identifier as this login item.
        ///
        /// If this process does not meet these requirements or you would like to have different acceptance criteria for incoming requests then a
        /// ``machService(name:clientRequirements:)`` may be used instead to explicitly specify this service's name and client requirements.
        case loginItem
        
        /// A process that is running as an XPC Mach service.
        ///
        /// Use this case to explicitly provide a service name and define the security requirements for connecting clients. This allows for retrieving a server for
        /// any Launch Daemons and Launch Agents as well as customizing client requirements for process types with built-in support.
        ///
        /// Because many processes on the system can talk to an XPC Mach service, when retrieving a server it is required that you specifiy the
        /// [code signing requirements](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)
        /// of any connecting clients:
        /// ```swift
        /// let reqString = "identifier \"com.example.AuthorizedClient\" and certificate leaf[subject.OU] = \"4L0ZG128MM\""
        /// var requirement: SecRequirement?
        /// if SecRequirementCreateWithString(reqString as CFString,
        ///                                   SecCSFlags(),
        ///                                   &requirement) == errSecSuccess,
        ///   let requirement = requirement {
        ///     let server = XPCServer.forThisProcess(ofType: .machService(name: "com.example.service",
        ///                                                                clientRequirements: [requirement]))
        ///    <# configure and start server #>
        /// }
        /// ```
        case machService(name: String, clientRequirements: [SecRequirement])
    }
    
    /// Returns the XPC server for this process.
    ///
    /// The request acceptance behavior of the returned service will depend on what type of ``ProcessType`` this server was created for.
    ///
    /// > Important: No requests will be processed until ``startAndBlock()`` or ``XPCNonBlockingServer/start()`` is called.
    ///
    /// By default this function will attempt to auto-detect which type of server this process represents. If this server's type cannot be detected then an error will be
    /// thrown. To resolve this, explicitly provide a ``ProcessType`` and use ``ProcessType/machService(name:clientRequirements:)`` for any
    /// configurations which do not have built-in support.
    public static func forThisProcess(ofType type: ProcessType = .autoDetect) throws -> XPCServer {
        switch type {
            case .autoDetect:
                if XPCServiceServer.isThisProcessAnXPCService {
                    return try XPCServiceServer.forThisXPCService()
                } else if XPCMachServer.isThisProcessABlessedHelperTool {
                    return try XPCMachServer.forThisBlessedHelperTool()
                } else if XPCMachServer.isThisProcessALoginItem {
                    return try XPCMachServer.forThisLoginItem()
                } else {
                    throw XPCError.misconfiguredServer(description: "Unable to auto-detect what type of XPC server " +
                                                                    "this is. Please provide an explicit type.")
                }
            case .xpcService:
                return try XPCServiceServer.forThisXPCService()
            case .blessedHelperTool:
                return try XPCMachServer.forThisBlessedHelperTool()
            case .loginItem:
                return try XPCMachServer.forThisLoginItem()
            case .machService(let name, let clientRequirements):
                let messageAcceptor = SecRequirementsMessageAcceptor(clientRequirements)
                return try XPCMachServer.getXPCMachServer(named: name, messageAcceptor: messageAcceptor)
        }
    }
}

// MARK: handler function wrappers

// These wrappers perform type erasure via their implemented protocols while internally maintaining type constraints
// This makes it possible to create heterogenous collections of them

fileprivate protocol XPCHandler {
    /// Whether as part of handling a request, an attempt should be made to create a reply.
    ///
    /// This doesn't necessarily mean the route actually has a reply type. This exists because for sequential reply types a reply should *not* be created as part
    /// of request handling; it may be created later if the sequence completes. XPC only allows a reply object to be created exactly once per request.
    var shouldCreateReply: Bool { get }
}

fileprivate extension XPCHandler {
    
    /// Validates that the incoming request matches the handler in terms of the presence of a message, reply, and/or sequential reply.
    ///
    /// The actual validation of the types themselves is performed as part of encoding/decoding and is intentionally not checked by this function.
    ///
    /// - Parameters:
    ///   - request: The incoming request.
    ///   - reply: The XPC reply object, if one exists.
    ///   - messageType: The parameter type of the registered handler, if applicable.
    ///   - replyType: The return type of the registered handler, if applicable.
    ///   - sequentialReplyType: The type used to provide sequential replies, if applicable.
    /// - Throws: If the check fails.
    func checkRequest(
        _ request: Request,
        reply: inout xpc_object_t?,
        messageType: Any.Type?,
        replyType: Any.Type?,
        sequentialReplyType: Any.Type?
    ) throws {
        var errorMessages = [String]()
        // Message
        if messageType == nil, request.containsPayload {
            errorMessages.append("Request had a message of type \(String(describing: request.route.messageType)), " +
                                 "but the handler registered with the server does not have a message parameter.")
        } else if let messageType = messageType, !request.containsPayload {
            errorMessages.append("Request did not contain a message, but the handler registered with the server has " +
                                 "a message parameter of type \(messageType).")
        }
        
        // Reply
        if replyType == nil, reply != nil && request.route.expectsReply {
            errorMessages.append("Request expects a reply of type \(String(describing: request.route.replyType)), " +
                                 "but the handler registered with the server has no return value.")
        } else if let replyType = replyType, reply == nil {
            errorMessages.append("Request does not expect a reply, but the handler registered with the server has a " +
                                 "return value of type \(replyType).")
        }
        
        // Reply sequence
        if sequentialReplyType != nil && request.route.sequentialReplyType == nil {
            errorMessages.append("Request expects a sequential reply of type " +
                                 String(describing: request.route.sequentialReplyType) + ", but the handler registered " +
                                 "with the server does not generate a sequential reply.")
        } else if sequentialReplyType == nil, let replySequenceType = request.route.sequentialReplyType {
            errorMessages.append("Request does not expect a sequential reply, but the handler registered with the " +
                                 "server has a sequential reply of type \(replySequenceType).")
        }
        
        if !errorMessages.isEmpty {
            throw XPCError.routeMismatch(routeName: request.route.pathComponents,
                                         description: errorMessages.joined(separator: "\n"))
        }
    }
}

// MARK: sync handler function wrappers

fileprivate protocol XPCHandlerSync: XPCHandler {
    func handle(request: Request, server: XPCServer, connection: xpc_connection_t, reply: inout xpc_object_t?) throws
}

fileprivate struct ConstrainedXPCHandlerWithoutMessageWithoutReplySync: XPCHandlerSync {
    var shouldCreateReply = true
    let handler: () throws -> Void
    
    func handle(request: Request, server: XPCServer, connection: xpc_connection_t, reply: inout xpc_object_t?) throws {
        try checkRequest(request, reply: &reply, messageType: nil, replyType: nil, sequentialReplyType: nil)
        try HandlerError.rethrow { try self.handler() }
    }
}

fileprivate struct ConstrainedXPCHandlerWithMessageWithoutReplySync<M: Decodable>: XPCHandlerSync {
    var shouldCreateReply = true
    let handler: (M) throws -> Void
    
    func handle(request: Request, server: XPCServer, connection: xpc_connection_t, reply: inout xpc_object_t?) throws {
        try checkRequest(request, reply: &reply, messageType: M.self, replyType: nil, sequentialReplyType: nil)
        let decodedMessage = try request.decodePayload(asType: M.self)
        try HandlerError.rethrow { try self.handler(decodedMessage) }
    }
}

fileprivate struct ConstrainedXPCHandlerWithoutMessageWithReplySync<R: Encodable>: XPCHandlerSync {
    var shouldCreateReply = true
    let handler: () throws -> R
    
    func handle(request: Request, server: XPCServer, connection: xpc_connection_t, reply: inout xpc_object_t?) throws {
        try checkRequest(request, reply: &reply, messageType: nil, replyType: R.self, sequentialReplyType: nil)
        let payload = try HandlerError.rethrow { try self.handler() }
        try Response.encodePayload(payload, intoReply: &reply!)
    }
}

fileprivate struct ConstrainedXPCHandlerWithMessageWithReplySync<M: Decodable, R: Encodable>: XPCHandlerSync {
    var shouldCreateReply = true
    let handler: (M) throws -> R
    
    func handle(request: Request, server: XPCServer, connection: xpc_connection_t, reply: inout xpc_object_t?) throws {
        try checkRequest(request, reply: &reply, messageType: M.self, replyType: R.self, sequentialReplyType: nil)
        let decodedMessage = try request.decodePayload(asType: M.self)
        let payload = try HandlerError.rethrow { try self.handler(decodedMessage) }
        try Response.encodePayload(payload, intoReply: &reply!)
    }
}

fileprivate struct ConstrainedXPCHandlerWithoutMessageWithSequentialReplySync<S: Encodable>: XPCHandlerSync {
    var shouldCreateReply = false
    let handler: (SequentialResultProvider<S>) -> Void
    
    func handle(request: Request, server: XPCServer, connection: xpc_connection_t, reply: inout xpc_object_t?) throws {
        try checkRequest(request, reply: &reply, messageType: nil, replyType: nil, sequentialReplyType: S.self)
        let sequenceProvider = SequentialResultProvider<S>(request: request, server: server, connection: connection)
        self.handler(sequenceProvider)
    }
}

fileprivate struct ConstrainedXPCHandlerWithMessageWithSequentialReplySync<M: Decodable, S: Encodable>: XPCHandlerSync {
    var shouldCreateReply = false
    let handler: (M, SequentialResultProvider<S>) -> Void
    
    func handle(request: Request, server: XPCServer, connection: xpc_connection_t, reply: inout xpc_object_t?) throws {
        try checkRequest(request, reply: &reply, messageType: M.self, replyType: nil, sequentialReplyType: S.self)
        let sequenceProvider = SequentialResultProvider<S>(request: request, server: server, connection: connection)
        let decodedMessage = try request.decodePayload(asType: M.self)
        self.handler(decodedMessage, sequenceProvider)
    }
}

// MARK: async handler function wrappers

@available(macOS 10.15.0, *)
fileprivate protocol XPCHandlerAsync: XPCHandler {
    func handle(
        request: Request,
        server: XPCServer,
        connection: xpc_connection_t,
        reply: inout xpc_object_t?
    ) async throws
}

@available(macOS 10.15.0, *)
fileprivate struct ConstrainedXPCHandlerWithoutMessageWithoutReplyAsync: XPCHandlerAsync {
    var shouldCreateReply = true
    let handler: () async throws -> Void
    
    func handle(
        request: Request,
        server: XPCServer,
        connection: xpc_connection_t,
        reply: inout xpc_object_t?
    ) async throws {
        try checkRequest(request, reply: &reply, messageType: nil, replyType: nil, sequentialReplyType: nil)
        try await HandlerError.rethrow { try await self.handler() }
    }
}

@available(macOS 10.15.0, *)
fileprivate struct ConstrainedXPCHandlerWithMessageWithoutReplyAsync<M: Decodable>: XPCHandlerAsync {
    var shouldCreateReply = true
    let handler: (M) async throws -> Void
    
    func handle(
        request: Request,
        server: XPCServer,
        connection: xpc_connection_t,
        reply: inout xpc_object_t?
    ) async throws {
        try checkRequest(request, reply: &reply, messageType: M.self, replyType: nil, sequentialReplyType: nil)
        let decodedMessage = try request.decodePayload(asType: M.self)
        try await HandlerError.rethrow { try await self.handler(decodedMessage) }
    }
}

@available(macOS 10.15.0, *)
fileprivate struct ConstrainedXPCHandlerWithoutMessageWithReplyAsync<R: Encodable>: XPCHandlerAsync {
    var shouldCreateReply = true
    let handler: () async throws -> R
    
    func handle(
        request: Request,
        server: XPCServer,
        connection: xpc_connection_t,
        reply: inout xpc_object_t?
    ) async throws {
        try checkRequest(request, reply: &reply, messageType: nil, replyType: R.self, sequentialReplyType: nil)
        let payload = try await HandlerError.rethrow { try await self.handler() }
        try Response.encodePayload(payload, intoReply: &reply!)
    }
}

@available(macOS 10.15.0, *)
fileprivate struct ConstrainedXPCHandlerWithMessageWithReplyAsync<M: Decodable, R: Encodable>: XPCHandlerAsync {
    var shouldCreateReply = true
    let handler: (M) async throws -> R
    
    func handle(
        request: Request,
        server: XPCServer,
        connection: xpc_connection_t,
        reply: inout xpc_object_t?
    ) async throws {
        try checkRequest(request, reply: &reply, messageType: M.self, replyType: R.self, sequentialReplyType: nil)
        let decodedMessage = try request.decodePayload(asType: M.self)
        let payload = try await HandlerError.rethrow { try await self.handler(decodedMessage) }
        try Response.encodePayload(payload, intoReply: &reply!)
    }
}

@available(macOS 10.15.0, *)
fileprivate struct ConstrainedXPCHandlerWithoutMessageWithSequentialReplyAsync<S: Encodable>: XPCHandlerAsync {
    var shouldCreateReply = false
    let handler: (SequentialResultProvider<S>) async -> Void
    
    func handle(
        request: Request,
        server: XPCServer,
        connection: xpc_connection_t,
        reply: inout xpc_object_t?
    ) async throws {
        try checkRequest(request, reply: &reply, messageType: nil, replyType: nil, sequentialReplyType: S.self)
        let sequenceProvider = SequentialResultProvider<S>(request: request, server: server, connection: connection)
        await self.handler(sequenceProvider)
    }
}

@available(macOS 10.15.0, *)
fileprivate struct ConstrainedXPCHandlerWithMessageWithSequentialReplyAsync<M: Decodable, S: Encodable>: XPCHandlerAsync {
    var shouldCreateReply = false
    let handler: (M, SequentialResultProvider<S>) async -> Void
    
    func handle(
        request: Request,
        server: XPCServer,
        connection: xpc_connection_t,
        reply: inout xpc_object_t?
    ) async throws {
        try checkRequest(request, reply: &reply, messageType: M.self, replyType: nil, sequentialReplyType: S.self)
        let sequenceProvider = SequentialResultProvider<S>(request: request, server: server, connection: connection)
        let decodedMessage = try request.decodePayload(asType: M.self)
        await self.handler(decodedMessage, sequenceProvider)
    }
}

// MARK: Error Handler

/// Wrapper around an error handling closure to ensure there's only ever one error handler regardless of whether it's synchronous or asynchronous.
enum ErrorHandler {
    case none
    case sync((XPCError) -> Void)
    case async((XPCError) async -> Void)
    
    func handle(_ error: XPCError) {
        switch self {
            case .none:
                break
            case .sync(let handler):
                handler(error)
            case .async(let handler):
                if #available(macOS 10.15, *) {
                    Task {
                        await handler(error)
                    }
                } else {
                    fatalError("async error handler was set on macOS prior to 10.15, this should not be possible")
                }
        }
    }
}
