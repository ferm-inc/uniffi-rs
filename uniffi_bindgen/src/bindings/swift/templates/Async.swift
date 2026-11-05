private let UNIFFI_RUST_FUTURE_POLL_READY: Int8 = 0
private let UNIFFI_RUST_FUTURE_POLL_WAKE: Int8 = 1

fileprivate let uniffiContinuationHandleMap = UniffiHandleMap<UnsafeContinuation<Int8, Never>>()

// Keep the handle alive until both polling and the cancellation handler finish.
private final class UniffiRustFuture: Sendable {
    let handle: UInt64
    private let free: @Sendable (UInt64) -> Void

    init(_ handle: UInt64, free: @escaping @Sendable (UInt64) -> Void) {
        self.handle = handle
        self.free = free
    }

    deinit { free(handle) }
}

func uniffiRustCallAsync<F, T>(
    rustFutureFunc: () -> UInt64,
    pollFunc: (UInt64, @escaping UniffiRustFutureContinuationCallback, UInt64) -> Void,
    completeFunc: (UInt64, UnsafeMutablePointer<RustCallStatus>) -> F,
    cancelFunc: @Sendable (UInt64) -> Void,
    freeFunc: @escaping @Sendable (UInt64) -> Void,
    liftFunc: (F) throws -> T,
    errorHandler: ((RustBuffer) throws -> Swift.Error)?
) async throws -> T {
    // Infallible Swift bindings use try! and cannot return CancellationError.
    let supportsCancellation = errorHandler != nil
    if supportsCancellation { try Task.checkCancellation() }
    {{ ensure_init_fn_name }}()
    let future = UniffiRustFuture(rustFutureFunc(), free: freeFunc)
    return try await withTaskCancellationHandler {
        var pollResult: Int8
        repeat {
            pollResult = await withUnsafeContinuation {
                pollFunc(future.handle, uniffiFutureContinuationCallback, uniffiContinuationHandleMap.insert(obj: $0))
            }
        } while pollResult != UNIFFI_RUST_FUTURE_POLL_READY
        // Consume the FFI value or error buffer even if Swift will discard the result.
        let result = Result {
            try liftFunc(makeRustCall(
                { completeFunc(future.handle, $0) },
                errorHandler: errorHandler
            ))
        }
        if supportsCancellation { try Task.checkCancellation() }
        return try result.get()
    } onCancel: {
        if supportsCancellation { cancelFunc(future.handle) }
    }
}

// Callback handlers for an async calls.  These are invoked by Rust when the future is ready.  They
// lift the return value or error and resume the suspended function.
fileprivate func uniffiFutureContinuationCallback(handle: UInt64, pollResult: Int8) {
    if let continuation = try? uniffiContinuationHandleMap.remove(handle: handle) {
        continuation.resume(returning: pollResult)
    } else {
        print("uniffiFutureContinuationCallback invalid handle")
    }
}

{%- if ci.has_async_callback_interface_definition() %}
private func uniffiTraitInterfaceCallAsync<T>(
    makeCall: @escaping () async throws -> T,
    handleSuccess: @escaping (T) -> (),
    handleError: @escaping (Int8, RustBuffer) -> (),
    droppedCallback: UnsafeMutablePointer<UniffiForeignFutureDroppedCallbackStruct>
) {
    let task = Task {
        // Note: it's important we call either `handleSuccess` or `handleError` exactly once.  Each
        // call consumes an Arc reference, which means there should be no possibility of a double
        // call.  The following code is structured so that will will never call both `handleSuccess`
        // and `handleError`, even in the face of weird errors.
        //
        // On platforms that need extra machinery to make C-ABI calls, like JNA or ctypes, it's
        // possible that we fail to make either call.  However, it doesn't seem like this is
        // possible on Swift since swift can just make the C call directly.
        var callResult: T
        do {
            callResult = try await makeCall()
        } catch {
            handleError(CALL_UNEXPECTED_ERROR, {{ Type::String.borrow()|lower_fn }}(String(describing: error)))
            return
        }
        handleSuccess(callResult)
    }
    let handle = UNIFFI_FOREIGN_FUTURE_HANDLE_MAP.insert(obj: task)
    droppedCallback.pointee = UniffiForeignFutureDroppedCallbackStruct(
        handle: handle,
        free: uniffiForeignFutureDroppedCallback
    )
}

private func uniffiTraitInterfaceCallAsyncWithError<T, E>(
    makeCall: @escaping () async throws -> T,
    handleSuccess: @escaping (T) -> (),
    handleError: @escaping (Int8, RustBuffer) -> (),
    lowerError: @escaping (E) -> RustBuffer,
    droppedCallback: UnsafeMutablePointer<UniffiForeignFutureDroppedCallbackStruct>
) {
    let task = Task {
        // See the note in uniffiTraitInterfaceCallAsync for details on `handleSuccess` and
        // `handleError`.
        var callResult: T
        do {
            callResult = try await makeCall()
        } catch let error as E {
            handleError(CALL_ERROR, lowerError(error))
            return
        } catch {
            handleError(CALL_UNEXPECTED_ERROR, {{ Type::String.borrow()|lower_fn }}(String(describing: error)))
            return
        }
        handleSuccess(callResult)
    }
    let handle = UNIFFI_FOREIGN_FUTURE_HANDLE_MAP.insert(obj: task)
    droppedCallback.pointee = UniffiForeignFutureDroppedCallbackStruct(
        handle: handle,
        free: uniffiForeignFutureDroppedCallback
    )
}

// Borrow the callback handle map implementation to store foreign future handles
// TODO: consolidate the handle-map code (https://github.com/mozilla/uniffi-rs/pull/1823)
fileprivate let UNIFFI_FOREIGN_FUTURE_HANDLE_MAP = UniffiHandleMap<UniffiForeignFutureTask>()

// Protocol for tasks that handle foreign futures.
//
// Defining a protocol allows all tasks to be stored in the same handle map.  This can't be done
// with the task object itself, since has generic parameters.
fileprivate protocol UniffiForeignFutureTask {
    func cancel()
}

extension Task: UniffiForeignFutureTask {}

private func uniffiForeignFutureDroppedCallback(handle: UInt64) {
    do {
        let task = try UNIFFI_FOREIGN_FUTURE_HANDLE_MAP.remove(handle: handle)
        // Set the cancellation flag on the task.  If it's still running, the code can check the
        // cancellation flag or call `Task.checkCancellation()`.  If the task has completed, this is
        // a no-op.
        task.cancel()
    } catch {
        print("uniffiForeignFutureDroppedCallback: handle missing from handlemap")
    }
}

// For testing
public func uniffiForeignFutureHandleCount{{ ci.namespace()|class_name }}() -> Int {
    UNIFFI_FOREIGN_FUTURE_HANDLE_MAP.count
}

{%- endif %}
