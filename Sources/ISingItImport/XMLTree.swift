import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A small in-memory XML element tree built with Foundation's `XMLParser`.
/// MusicXML files are small enough that a tree is simpler than streaming.
final class XMLElement {
    let name: String
    let attributes: [String: String]
    var children: [XMLElement] = []
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLElement? { children.first { $0.name == name } }
    func children(_ name: String) -> [XMLElement] { children.filter { $0.name == name } }
    func has(_ name: String) -> Bool { child(name) != nil }

    /// Text of a direct child, trimmed.
    func value(_ name: String) -> String? {
        child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func double(_ name: String) -> Double? { value(name).flatMap(Double.init) }
    func int(_ name: String) -> Int? { value(name).flatMap { Int($0) ?? Double($0).map { Int($0) } } }

    /// All descendants with a given name, depth first.
    func descendants(_ name: String) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: child.descendants(name))
        }
        return result
    }
}

enum XMLTreeError: Error, CustomStringConvertible {
    case parse(String)
    case empty

    var description: String {
        switch self {
        case .parse(let message): "XML parse error: \(message)"
        case .empty: "XML document is empty"
        }
    }
}

final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [XMLElement] = []
    private(set) var root: XMLElement?

    static func parse(_ data: Data) throws -> XMLElement {
        let parser = XMLParser(data: data)
        let builder = XMLTreeBuilder()
        parser.delegate = builder
        // MusicXML files reference an external DTD; never fetch it.
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw XMLTreeError.parse(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard let root = builder.root else { throw XMLTreeError.empty }
        return root
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        let element = XMLElement(name: elementName, attributes: attributeDict)
        stack.last?.children.append(element)
        if stack.isEmpty { root = element }
        stack.append(element)
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}
