import Foundation
import simd

private struct PhonoscopeExpressionInstruction: Decodable {
    let op: String
    let value: Double?
    let key: String?
    let fn: String?
    let argc: Int?
}

struct PhonoscopeExpression: Decodable {
    let source: String
    private let code: [PhonoscopeExpressionInstruction]

    private enum CodingKeys: String, CodingKey {
        case source = "$expr"
        case code
    }

    static func evaluate(_ value: PhonoscopeJSONValue?, inputs: [String: Double], fallback: Double) -> Double {
        guard let value else { return fallback }
        if let number = value.numberValue { return number }
        guard let object = value.objectValue,
              let source = object["$expr"]?.stringValue,
              let encoded = try? JSONSerialization.data(withJSONObject: jsonObject(value)),
              let expression = try? JSONDecoder().decode(PhonoscopeExpression.self, from: encoded)
        else { return fallback }
        _ = source
        return expression.evaluate(inputs: inputs)
    }

    private static func jsonObject(_ value: PhonoscopeJSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(jsonObject)
        case .object(let values): return values.mapValues(jsonObject)
        }
    }

    func evaluate(inputs: [String: Double]) -> Double {
        var stack: [Double] = []
        stack.reserveCapacity(16)
        func pop() -> Double { stack.popLast() ?? 0 }
        for instruction in code {
            switch instruction.op {
            case "const": stack.append(instruction.value ?? 0)
            case "load": stack.append(inputs[instruction.key ?? ""] ?? 0)
            case "neg": stack.append(-pop())
            case "not": stack.append(pop() == 0 ? 1 : 0)
            case "add": let b = pop(), a = pop(); stack.append(a + b)
            case "sub": let b = pop(), a = pop(); stack.append(a - b)
            case "mul": let b = pop(), a = pop(); stack.append(a * b)
            case "div": let b = pop(), a = pop(); stack.append(abs(b) < 0.000_001 ? 0 : a / b)
            case "mod": let b = pop(), a = pop(); stack.append(abs(b) < 0.000_001 ? 0 : a.truncatingRemainder(dividingBy: b))
            case "pow": let b = pop(), a = pop(); stack.append(Foundation.pow(a, b))
            case "lt": let b = pop(), a = pop(); stack.append(a < b ? 1 : 0)
            case "lte": let b = pop(), a = pop(); stack.append(a <= b ? 1 : 0)
            case "gt": let b = pop(), a = pop(); stack.append(a > b ? 1 : 0)
            case "gte": let b = pop(), a = pop(); stack.append(a >= b ? 1 : 0)
            case "eq": let b = pop(), a = pop(); stack.append(a == b ? 1 : 0)
            case "neq": let b = pop(), a = pop(); stack.append(a != b ? 1 : 0)
            case "and": let b = pop(), a = pop(); stack.append(a != 0 && b != 0 ? 1 : 0)
            case "or": let b = pop(), a = pop(); stack.append(a != 0 || b != 0 ? 1 : 0)
            case "call":
                let count = max(0, instruction.argc ?? 0)
                let args = (0..<count).map { _ in pop() }.reversed()
                stack.append(call(instruction.fn ?? "", Array(args)))
            default: break
            }
            if let last = stack.last, !last.isFinite { stack[stack.count - 1] = 0 }
        }
        return stack.last ?? 0
    }

    private func call(_ name: String, _ values: [Double]) -> Double {
        let a = values[safe: 0] ?? 0
        let b = values[safe: 1] ?? 0
        let c = values[safe: 2] ?? 0
        switch name {
        case "sin": return sin(a)
        case "cos": return cos(a)
        case "tan": return tan(a)
        case "abs": return abs(a)
        case "sqrt": return a >= 0 ? sqrt(a) : 0
        case "floor": return floor(a)
        case "ceil": return ceil(a)
        case "fract": return a - floor(a)
        case "exp": return Foundation.exp(a)
        case "log": return a > 0 ? Foundation.log(a) : 0
        case "min": return values.min() ?? 0
        case "max": return values.max() ?? 0
        case "pow": return Foundation.pow(a, b)
        case "clamp": return min(max(a, b), c)
        case "mix": return a + (b - a) * c
        case "step": return b < a ? 0 : 1
        case "smoothstep":
            guard b != a else { return 0 }
            let t = min(max((c - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        case "select": return a != 0 ? b : c
        case "noise":
            let value = sin(a * 12.9898 + b * 78.233 + c * 37.719) * 43_758.5453
            return value - floor(value)
        default: return a
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
