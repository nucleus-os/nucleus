@_spi(NucleusCompositor) import NucleusLayers

extension ViewLayerPublisher {
    func publishAnimations(
        snapshot: ViewLayerSnapshot,
        state: inout VisualLayerCache,
        transaction: inout LayerTransaction,
        didMutate: inout Bool,
        metrics: inout ViewPublicationMetrics
    ) {
        for request in snapshot.animationRequests
        where request.generation > state.animationGeneration {
            switch request.operation {
            case .add(let animation):
                transaction.mutations.append(.animationAdded(
                    layer: state.layer.id,
                    animation))
            case .remove(let keyPath):
                transaction.mutations.append(.animationRemoved(
                    layer: state.layer.id,
                    keyPath))
            }
            state.animationGeneration = max(
                state.animationGeneration,
                request.generation)
            didMutate = true
            metrics.animationRequests &+= 1
        }
    }

    func bindTransactionCompletions(
        _ handles: [TransactionCompletionHandle],
        to transaction: inout LayerTransaction
    ) -> PresentationCompletionToken? {
        guard !handles.isEmpty else { return nil }
        let token = context.runtimeHost.presentationCompletions.register { result in
            let outcome = TransactionOutcome(result)
            for handle in handles {
                handle.resolve(outcome)
            }
        }
        transaction.completionToken = token.rawValue
        return token
    }

    func bindAnimationPresentationTiming(
        to transaction: inout LayerTransaction
    ) throws(LayerError) {
        guard transaction.mutations.contains(where: {
            if case .animationAdded = $0 { return true }
            return false
        }), !(context.commitSink is InMemoryCommitSink)
        else { return }
        let report = try context.queryDisplayLink()
        transaction.predictedPresentationNanoseconds =
            report.predictedPresentationNanoseconds
        transaction.targetPresentationNanoseconds =
            report.targetPresentationNanoseconds
    }

    func resolveAcceptedInMemoryCompletions(
        transaction: borrowing LayerTransaction,
        transactionToken: PresentationCompletionToken?
    ) {
        guard context.commitSink is InMemoryCommitSink else { return }
        if let transactionToken {
            context.runtimeHost.presentationCompletions.resolve(
                transactionToken,
                result: .completed)
        }
        for token in animationCompletionTokens(in: transaction)
        where token != 0 {
            context.runtimeHost.presentationCompletions.resolve(
                rawToken: token,
                result: .completed)
        }
    }

    func resolveRejectedCompletions(
        transaction: borrowing LayerTransaction,
        transactionToken: PresentationCompletionToken?,
        handles: [TransactionCompletionHandle]
    ) {
        for token in animationCompletionTokens(in: transaction)
        where token != 0 {
            context.runtimeHost.presentationCompletions.resolve(
                rawToken: token,
                result: .failed)
        }
        if let transactionToken {
            context.runtimeHost.presentationCompletions.resolve(
                transactionToken,
                result: .failed)
        } else {
            for handle in handles {
                handle.resolve(.failed)
            }
        }
    }

    private func animationCompletionTokens(
        in transaction: borrowing LayerTransaction
    ) -> [UInt64] {
        transaction.mutations.compactMap {
            if case .animationAdded(_, let animation) = $0 {
                return animation.completionToken
            }
            return nil
        }
    }
}
