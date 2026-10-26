import UIKit

/// The message field under a long-pressed notification, as in Messages: it comes up with the
/// keyboard, so a long press goes straight to typing. Return or the arrow sends.
final class ReplyBar: UIView, UITextFieldDelegate {
    var onSend: ((String) -> Void)?

    private let field = UITextField()
    private let sendButton = UIButton(type: .custom)
    private let glass = UIVisualEffectView(effect: UIGlassEffect())

    private static let fieldHeight: CGFloat = 40
    private static let margin: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = .flexibleHeight

        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        field.placeholder = String(localized: "Message")
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .send
        field.enablesReturnKeyAutomatically = true
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(field)

        sendButton.accessibilityLabel = String(localized: "Send")
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(sendButton)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Self.margin),
            glass.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Self.margin),
            glass.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            glass.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.fieldHeight),

            field.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            field.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            field.heightAnchor.constraint(equalTo: glass.contentView.heightAnchor),
            sendButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            sendButton.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -5),
            sendButton.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
        ])
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        textChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The accessory's height comes from its constraints.
    override var intrinsicContentSize: CGSize { .zero }

    /// The app's own-bubble blue.
    private static let sendColor = UIColor(red: 0, green: 0.478, blue: 1, alpha: 1)

    func focus() {
        field.becomeFirstResponder()
    }

    /// Puts back a reply that didn't send, so it isn't lost.
    func restore(_ text: String) {
        guard field.text?.isEmpty ?? true else { return }
        field.text = text
        textChanged()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        send()
        return false
    }

    @objc private func textChanged() {
        let canSend = !(field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = canSend
        // Gray until there's something to send, as in the app's own field.
        let symbol = UIImage.SymbolConfiguration(pointSize: 30)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, canSend ? Self.sendColor : .tertiaryLabel]))
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill", withConfiguration: symbol), for: .normal)
    }

    @objc private func send() {
        let text = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        field.text = ""
        textChanged()
        onSend?(text)
    }
}
