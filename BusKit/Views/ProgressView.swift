import SwiftUI

/// Modal popup showing progress, either circular or linear, determinate (`progress` set) or indeterminate (`progress` nil).
@available(macOS 15.0, *)
public struct ProgressPopupView: View {
    let messageProgress: String
    let progress: Double?
    let isCircular: Bool
    let cancelAction: (() -> Void)?

    /// - Parameters:
    ///   - messageProgress: Message to display below the progress indicator.
    ///   - isCircular: Format of the progress indicator, true circular, false linear.
    ///   - progress: Progress value between 0.0 and 1.0, or nil for indeterminate progress.
    public init(messageProgress: String, isCircular: Bool = true, progress: Double? = nil, cancelAction: (() -> Void)? = nil) {
        self.messageProgress = messageProgress
        self.isCircular = isCircular
        self.progress = progress
        self.cancelAction = cancelAction
    }

    public var body: some View {
        VStack(spacing: 16) {
            progressIndicator
                .controlSize(.large)
            Text(messageProgress)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel") {
                cancelAction?()
            }
            .disabled(cancelAction == nil)
            
        }
        .padding(32)
        .frame(width: 260)
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if isCircular {
            circularProgress
        } else {
            linearProgress
        }
    }

    @ViewBuilder
    private var circularProgress: some View {
        if let progress {
            ProgressView(value: progress).progressViewStyle(.circular)
        } else {
            ProgressView().progressViewStyle(.circular)
        }
    }

    @ViewBuilder
    private var linearProgress: some View {
        if let progress {
            ProgressView(value: progress).progressViewStyle(.linear)
        } else {
            ProgressView().progressViewStyle(.linear)
        }
    }
}
