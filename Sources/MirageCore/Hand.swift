/// 手部 21 個關節，順序與 MediaPipe Hands 相同，日後替換追蹤模型時上層不必改。
public enum Joint: Int, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMCP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

public struct Vec2: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func squaredDistance(to other: Vec2) -> Double {
        (x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)
    }

    public func distance(to other: Vec2) -> Double {
        squaredDistance(to: other).squareRoot()
    }
}

/// 正規化影像座標（0...1，原點左下，未鏡像）與信心值。
public struct JointSample: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var c: Double

    public init(x: Double, y: Double, c: Double) {
        self.x = x
        self.y = y
        self.c = c
    }
}

public enum Chirality: String, Codable, Sendable {
    case left, right, unknown
}

public struct Hand: Codable, Sendable, Equatable {
    public var chirality: Chirality
    /// 依 `Joint` 順序排列的 21 個關節。
    public var joints: [JointSample]

    public init(chirality: Chirality, joints: [JointSample]) {
        precondition(joints.count == Joint.allCases.count)
        self.chirality = chirality
        self.joints = joints
    }

    public subscript(joint: Joint) -> JointSample {
        joints[joint.rawValue]
    }

    public var meanConfidence: Double {
        joints.reduce(0) { $0 + $1.c } / Double(joints.count)
    }
}
