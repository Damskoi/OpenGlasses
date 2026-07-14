import Foundation

/// Routes Gemini WebSocket tool calls to native tools first, then OpenClaw bridge.
/// Used in Gemini Live mode when Gemini issues function calls over the WebSocket.
@MainActor
class ToolCallRouter {
    private let bridge: OpenClawBridge
    var nativeToolRouter: NativeToolRouter?
    private var inFlightTasks: [String: Task<Void, Never>] = [:]

    /// Plan BR P1: per-session circuit breaker — bounds runaway tool loops. The session
    /// manager resets its user-turn window and reads `suspendedToolNames` when re-declaring
    /// tools on reconnect.
    private var breaker = ToolCallBreaker()
    var suspendedToolNames: Set<String> { breaker.suspendedTools }

    /// Callback to pause/resume camera streaming during tool execution (prevents instability).
    var onToolExecutionStarted: (() -> Void)?
    var onToolExecutionFinished: (() -> Void)?

    init(bridge: OpenClawBridge) {
        self.bridge = bridge
    }

    /// A user turn breaks the consecutive-call window (wired to input transcription).
    func noteUserTurn() {
        breaker.recordUserTurn()
    }

    func handleToolCall(
        _ call: GeminiFunctionCall,
        sendResponse: @escaping ([String: Any]) -> Void
    ) {
        let callId = call.id
        let callName = call.name

        NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
              callName, callId, String(describing: call.args))

        // Plan BR P1: refuse suspended/runaway calls without executing — the message rides
        // back as the tool error so the model learns in-band and informs the user.
        if case .suspended(let message) = breaker.admit(toolName: callName) {
            NSLog("[ToolCall] Breaker refused %@ (id: %@)", callName, callId)
            sendResponse(buildToolResponse(callId: callId, name: callName, result: .failure(message)))
            return
        }

        // Pause camera/audio streaming during tool execution to prevent instability
        onToolExecutionStarted?()

        let argsKey = ToolCallBreaker.argsKey(call.args)
        let task = Task { @MainActor in
            // Route through NativeToolRouter first (handles native → MCP → OpenClaw cascade)
            var result: ToolResult
            if let router = nativeToolRouter {
                result = await router.handleToolCall(name: callName, args: call.args)
            } else if Config.isOpenClawAgentActive {
                // Fallback: direct OpenClaw delegation (legacy path). BK P0: only as an active
                // agentic capability — delegateTask itself now fails closed otherwise, but don't
                // route here at all with Agent Mode off.
                let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
                result = await bridge.delegateTask(task: taskDesc, toolName: callName)
            } else {
                result = .failure("Unknown tool '\(callName)'")
            }

            // Resume streaming after tool execution
            self.onToolExecutionFinished?()

            guard !Task.isCancelled else {
                NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
                return
            }

            // Identical-failure tracking: a tripped breaker appends its notice to the error
            // so the model stops retrying instead of hammering the same broken call.
            let succeeded: Bool
            if case .success = result { succeeded = true } else { succeeded = false }
            if let notice = self.breaker.recordOutcome(
                toolName: callName, argsKey: argsKey, success: succeeded),
               case .failure(let error) = result {
                result = .failure("\(error)\n\(notice)")
            }

            NSLog("[ToolCall] Result for %@ (id: %@): %@",
                  callName, callId, String(describing: result))

            let response = self.buildToolResponse(callId: callId, name: callName, result: result)
            sendResponse(response)

            self.inFlightTasks.removeValue(forKey: callId)
        }

        inFlightTasks[callId] = task
    }

    func cancelToolCalls(ids: [String]) {
        for id in ids {
            if let task = inFlightTasks[id] {
                NSLog("[ToolCall] Cancelling in-flight call: %@", id)
                task.cancel()
                inFlightTasks.removeValue(forKey: id)
            }
        }
        bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
    }

    func cancelAll() {
        for (id, task) in inFlightTasks {
            NSLog("[ToolCall] Cancelling in-flight call: %@", id)
            task.cancel()
        }
        inFlightTasks.removeAll()
    }

    // MARK: - Private

    private func buildToolResponse(
        callId: String,
        name: String,
        result: ToolResult
    ) -> [String: Any] {
        // Frame untrusted external content (web, OCR, captions, gateway, MCP, …) as data so
        // injected instructions inside it are visibly bounded, not treated as commands.
        let responseValue: [String: Any]
        switch result {
        case .success(let text):
            let isKnownNative = nativeToolRouter?.registry.tool(named: name) != nil
            let framed = PromptInjectionPolicy.isUntrustedOutput(toolName: name, isKnownNativeTool: isKnownNative)
                ? PromptInjectionPolicy.wrap(toolName: name, content: text)
                : text
            responseValue = ["result": framed]
        case .failure(let error):
            responseValue = ["error": error]
        }
        return [
            "toolResponse": [
                "functionResponses": [
                    [
                        "id": callId,
                        "name": name,
                        "response": responseValue
                    ]
                ]
            ]
        ]
    }
}
