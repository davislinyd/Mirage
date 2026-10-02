import AppKit

/// 選單裡的水平滑桿（`item` 的 view）：上一行是標題與目前值，下一行是兩端標示夾著滑桿。只停在每 `step` 一格，
/// 拖動時即時呼叫 `onChange`。
@MainActor
final class MenuSlider: NSView {
    let item = NSMenuItem()
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    private let onChange: (Double) -> Void

    init(
        title: String, range: ClosedRange<Double>, step: Double, value: Double, ends: (String, String),
        format: @escaping (Double) -> String, onChange: @escaping (Double) -> Void
    ) {
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        self.format = format
        self.onChange = onChange
        super.init(frame: .zero)
        slider.numberOfTickMarks = Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        valueLabel.stringValue = format(value)
        valueLabel.textColor = .secondaryLabelColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .menuFont(ofSize: 0)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let header = NSStackView(views: [titleLabel, NSView(), valueLabel])
        let row = NSStackView(views: [Self.endLabel(ends.0), slider, Self.endLabel(ends.1)])
        row.spacing = 6
        let stack = NSStackView(views: [header, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        // 左邊對齊一般選單項目的文字（勾選欄之後）。
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 21, bottom: 4, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 260),
            header.widthAnchor.constraint(equalTo: row.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -35),
        ])
        frame.size = fittingSize
        item.view = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        valueLabel.stringValue = format(slider.doubleValue)
        onChange(slider.doubleValue)
    }

    private static func endLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }
}
