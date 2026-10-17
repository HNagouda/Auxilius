import Foundation
import OSLog

/// A circuit the model traced from the page, as the JSON inside a ```circuit block.
/// The transcript pane draws it as a schematic; chats get it as a netlist, which they reason over better.
struct Circuit: Decodable {
    struct Part: Decodable {
        // wire, resistor, capacitor, inductor, battery, voltage_source, current_source, diode, switch or ground.
        let type: String
        let name: String?
        let value: String?
        let note: String?
        // Grid points [x, y]. Two-terminal parts run from `from` to `to`; for sources `to` is the + side.
        let from: [Double]?
        let to: [Double]?
        // Ground only.
        let at: [Double]?
    }

    struct NodeLabel: Decodable {
        let at: [Double]
        let text: String
    }

    let title: String?
    let parts: [Part]
    let nodes: [NodeLabel]?
}

enum Netlist {
    // SPICE letters for each part type that becomes a netlist line. Wires and grounds only join nodes.
    private static let prefixes = [
        "resistor": "R", "capacitor": "C", "inductor": "L", "battery": "V",
        "voltage_source": "V", "current_source": "I", "diode": "D", "switch": "S",
    ]
    private static let logger = Logger(subsystem: "auxilius", category: "netlist")

    /// The transcript with every ```circuit block swapped for a netlist block a chat can read.
    static func chatVersion(of transcript: String) -> String {
        var output = ""
        var remainder = Substring(transcript)
        while let start = remainder.range(of: "```circuit"), let end = remainder[start.upperBound...].range(of: "```") {
            output += remainder[..<start.lowerBound]
            let json = remainder[start.upperBound..<end.lowerBound]
            output += netlistBlock(for: String(json))
            remainder = remainder[end.upperBound...]
        }
        return output + remainder
    }

    private static func netlistBlock(for json: String) -> String {
        do {
            let circuit = try JSONDecoder().decode(Circuit.self, from: Data(json.utf8))
            return "```spice\n\(netlist(for: circuit))\n```"
        } catch {
            // Better to show the chat the model's raw block than to drop the circuit.
            logger.error("Circuit block did not decode: \(error.localizedDescription)")
            return "```json\(json)```"
        }
    }

    /// '2 kΩ' -> '2k', '100 µF' -> '100u', '12 V' -> '12', '1 MΩ' -> '1Meg'.
    static func spiceValue(_ value: String) -> String {
        var compact = value.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "μ", with: "u")
        for unit in ["ohms", "ohm", "Ω", "F", "H", "V", "A"] where compact.hasSuffix(unit) && compact.count > unit.count {
            compact.removeLast(unit.count)
            break
        }
        if compact.hasSuffix("M") {
            compact = String(compact.dropLast()) + "Meg"
        }
        return compact
    }
}

extension Netlist {
    static func netlist(for circuit: Circuit) -> String {
        let nodes = NodeNames(circuit)
        var counters: [String: Int] = [:]
        var lines = ["* \(circuit.title ?? "Circuit")"]
        var notes: [String] = []

        for part in circuit.parts {
            guard let prefix = prefixes[part.type], let from = part.from, let to = part.to else { continue }

            counters[prefix, default: 0] += 1
            let name = part.name ?? "\(prefix)\(counters[prefix]!)"
            let value = part.value.map(spiceValue) ?? ""
            let a = nodes.name(of: from), b = nodes.name(of: to)
            switch part.type {
            // SPICE lists a voltage source + node first; `to` is the + side.
            case "battery", "voltage_source": lines.append("\(name) \(b) \(a) DC \(value)")
            case "current_source": lines.append("\(name) \(a) \(b) DC \(value)")
            case "diode": lines.append("\(name) \(a) \(b) D")
            case "switch": lines.append("\(name) \(a) \(b) \(value.isEmpty ? "open" : value)")
            default: lines.append("\(name) \(a) \(b) \(value)")
            }
            if let note = part.note {
                notes.append("* \(name): \(note)")
            }
        }

        return (lines + notes).joined(separator: "\n")
    }
}

/// Names the electrical nodes: grid points joined by wires are one node.
/// Ground is node 0; with no ground drawn, the - side of the first source is.
private struct NodeNames {
    private var parent: [String: String] = [:]
    private var names: [String: String] = [:]

    init(_ circuit: Circuit) {
        for part in circuit.parts {
            for point in [part.from, part.to, part.at].compactMap({ $0 }) {
                parent[Self.key(point)] = parent[Self.key(point)] ?? Self.key(point)
            }
            if part.type == "wire", let from = part.from, let to = part.to {
                join(Self.key(from), Self.key(to))
            }
        }

        let ground = circuit.parts.first { $0.type == "ground" }?.at
            ?? circuit.parts.first { ["battery", "voltage_source", "current_source"].contains($0.type) }?.from
        if let ground {
            names[root(Self.key(ground))] = "0"
        }
        for label in circuit.nodes ?? [] where names[root(Self.key(label.at))] == nil {
            names[root(Self.key(label.at))] = label.text.replacingOccurrences(of: " ", with: "_")
        }
        var counter = 0
        for point in parent.keys.sorted() where names[root(point)] == nil {
            counter += 1
            names[root(point)] = "n\(counter)"
        }
    }

    func name(of point: [Double]) -> String {
        names[root(Self.key(point))] ?? "?"
    }

    private static func key(_ point: [Double]) -> String {
        point.map { String($0) }.joined(separator: ",")
    }

    private func root(_ key: String) -> String {
        var current = key
        while let next = parent[current], next != current {
            current = next
        }
        return current
    }

    private mutating func join(_ a: String, _ b: String) {
        parent[root(a)] = root(b)
    }
}
