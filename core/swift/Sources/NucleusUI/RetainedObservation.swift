import Observation

/// Whether one retained observation keeps its model alive.
///
/// This choice is explicit because both lifetimes are useful: a controller
/// commonly owns its model, while a view often only projects a model owned by
/// the application. The retained lifecycle owner always owns the token.
package enum RetainedObservationCapturePolicy: Sendable {
    case strong
    case weak
}

/// One dependency-tracked update bound to a retained UI lifecycle.
///
/// The token is intentionally package-scoped while the production API shape
/// settles. Callers normally let the view or controller own it; retaining the
/// returned token only enables explicit early cancellation.
@MainActor
package final class RetainedObservationToken {
    package static private(set) var liveCount = 0

    private let uiContext: UIContext
    private let configuration: TransactionConfiguration
    private var ownerProvider: (@MainActor () -> AnyObject?)?
    private var modelProvider: (@MainActor () -> AnyObject?)?
    private var update: (@MainActor (AnyObject, AnyObject) -> Void)?
    private var completion:
        (@MainActor (AnyObject, TransactionOutcome) -> Void)?
    private var cancellationHandler: (@MainActor () -> Void)?
    private var scheduledUpdate: Task<Void, Never>?
    private var updateGeneration: UInt64 = 0

    package private(set) var isCancelled = false

    fileprivate init<Owner: AnyObject, Model: AnyObject>(
        owner: Owner,
        uiContext: UIContext,
        model: Model,
        capturePolicy: RetainedObservationCapturePolicy,
        configuration: TransactionConfiguration,
        update: @escaping @MainActor (Owner, Model) -> Void,
        completion:
            (@MainActor (Owner, TransactionOutcome) -> Void)?
    ) {
        weak let weakOwner = owner
        ownerProvider = { weakOwner }

        switch capturePolicy {
        case .strong:
            modelProvider = { model }
        case .weak:
            weak let weakModel = model
            modelProvider = { weakModel }
        }

        self.uiContext = uiContext
        self.configuration = configuration
        self.update = { erasedOwner, erasedModel in
            guard let owner = erasedOwner as? Owner,
                  let model = erasedModel as? Model
            else { return }
            update(owner, model)
        }
        if let completion {
            self.completion = { erasedOwner, outcome in
                guard let owner = erasedOwner as? Owner else { return }
                completion(owner, outcome)
            }
        } else {
            self.completion = nil
        }
        Self.liveCount += 1
    }

    isolated deinit {
        scheduledUpdate?.cancel()
        Self.liveCount -= 1
    }

    fileprivate func installCancellationHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        precondition(cancellationHandler == nil)
        cancellationHandler = handler
    }

    fileprivate func start() {
        guard !isCancelled else { return }
        performUpdate()
    }

    package func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        updateGeneration &+= 1
        scheduledUpdate?.cancel()
        scheduledUpdate = nil
        ownerProvider = nil
        modelProvider = nil
        update = nil
        completion = nil
        let cancellationHandler = cancellationHandler
        self.cancellationHandler = nil
        cancellationHandler?()
    }

    private func dependencyDidChange() {
        guard !isCancelled, scheduledUpdate == nil else { return }
        scheduledUpdate = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.scheduledUpdate = nil
            self.performUpdate()
        }
    }

    private func performUpdate() {
        guard !isCancelled,
              let owner = ownerProvider?(),
              let model = modelProvider?(),
              let update
        else {
            cancel()
            return
        }

        updateGeneration &+= 1
        let generation = updateGeneration
        let completion = self.completion
        let handle = withObservationTracking {
            // The context scope is important when an update constructs an
            // explicit replacement subtree. Transaction state itself is
            // context-owned and applies one immutable mutation policy.
            uiContext.construct {
                Transaction.runNonThrowing(
                    in: uiContext,
                    configuration: configuration,
                    requestsPresentationCompletion: completion != nil
                ) {
                    update(owner, model)
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.dependencyDidChange()
            }
        }

        guard let completion, let handle else { return }
        handle.onCompletion { [weak self] outcome in
            guard let self,
                  !self.isCancelled,
                  self.updateGeneration == generation,
                  let owner = self.ownerProvider?()
            else { return }
            completion(owner, outcome)
        }
    }
}

package extension View {
    /// Track the model dependencies read by `update` and write subsequent
    /// changes into this retained view.
    @discardableResult
    func observe<Model: AnyObject>(
        _ model: Model,
        capturePolicy: RetainedObservationCapturePolicy = .weak,
        configuration: TransactionConfiguration = .immediate,
        update: @escaping @MainActor (View, Model) -> Void,
        completion:
            (@MainActor (View, TransactionOutcome) -> Void)? = nil
    ) -> RetainedObservationToken {
        let token = RetainedObservationToken(
            owner: self,
            uiContext: uiContext,
            model: model,
            capturePolicy: capturePolicy,
            configuration: configuration,
            update: update,
            completion: completion)
        let identity = ObjectIdentifier(token)
        token.installCancellationHandler { [weak self] in
            self?.ownedObservationTokens[identity] = nil
        }
        ownedObservationTokens[identity] = token
        token.start()
        return token
    }

    func cancelOwnedObservations() {
        let tokens = Array(ownedObservationTokens.values)
        ownedObservationTokens.removeAll(keepingCapacity: false)
        for token in tokens {
            token.cancel()
        }
    }
}

package extension ViewController {
    /// Track model dependencies for a controller without introducing a second
    /// view-construction or reconciliation path.
    @discardableResult
    func observe<Model: AnyObject>(
        _ model: Model,
        capturePolicy: RetainedObservationCapturePolicy = .weak,
        configuration: TransactionConfiguration = .immediate,
        update:
            @escaping @MainActor (ViewController, Model) -> Void,
        completion:
            (@MainActor (ViewController, TransactionOutcome) -> Void)? = nil
    ) -> RetainedObservationToken {
        let rootView = view
        let token = RetainedObservationToken(
            owner: self,
            uiContext: rootView.uiContext,
            model: model,
            capturePolicy: capturePolicy,
            configuration: configuration,
            update: update,
            completion: completion)
        let identity = ObjectIdentifier(token)
        token.installCancellationHandler { [weak self] in
            self?.ownedObservationTokens[identity] = nil
        }
        ownedObservationTokens[identity] = token
        token.start()
        return token
    }

    func cancelOwnedObservations() {
        let tokens = Array(ownedObservationTokens.values)
        ownedObservationTokens.removeAll(keepingCapacity: false)
        for token in tokens {
            token.cancel()
        }
    }
}
