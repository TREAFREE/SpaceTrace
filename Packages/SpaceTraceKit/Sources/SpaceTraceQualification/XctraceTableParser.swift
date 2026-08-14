import Foundation

struct XctraceCell: Equatable, Sendable {
    let rawValue: String
    let formattedValue: String?

    var int64Value: Int64? {
        Int64(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var doubleValue: Double? {
        Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var booleanValue: Bool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "0": false
        case "1": true
        default:
            switch formattedValue?.lowercased() {
            case "no", "false": false
            case "yes", "true": true
            default: nil
            }
        }
    }

    var displayValue: String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? (formattedValue ?? "") : raw
    }
}

struct XctraceTable: Sendable {
    let schemaName: String
    let rows: [[String: XctraceCell?]]
}

struct XctraceTableParser: Sendable {
    func parse(_ url: URL) throws -> XctraceTable {
        guard let parser = XMLParser(contentsOf: url) else {
            throw InstrumentsActivityMonitorAnalysisError.malformedXML
        }
        let delegate = Delegate()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure
                ?? InstrumentsActivityMonitorAnalysisError.malformedXML
        }
        guard let schemaName = delegate.schemaName,
              delegate.columns.isEmpty == false,
              delegate.rows.isEmpty == false else {
            throw InstrumentsActivityMonitorAnalysisError.malformedXML
        }
        return XctraceTable(schemaName: schemaName, rows: delegate.rows)
    }
}

private extension XctraceTableParser {
    final class Delegate: NSObject, XMLParserDelegate {
        struct PendingCell {
            let depth: Int
            let reference: String?
            let formattedValue: String?
            var rawValue = ""
        }

        struct PendingDefinition {
            let depth: Int
            let id: String
            let formattedValue: String?
            var rawValue = ""
        }

        var schemaName: String?
        var columns: [String] = []
        var rows: [[String: XctraceCell?]] = []
        var failure: InstrumentsActivityMonitorAnalysisError?

        private var depth = 0
        private var rowDepth: Int?
        private var rowCells: [XctraceCell?] = []
        private var pendingCell: PendingCell?
        private var pendingDefinitions: [PendingDefinition] = []
        private var mnemonicDepth: Int?
        private var mnemonicText = ""
        private var definitions: [String: XctraceCell] = [:]

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            depth += 1
            if elementName == "schema" {
                schemaName = attributeDict["name"]
            }
            if elementName == "mnemonic", rowDepth == nil {
                mnemonicDepth = depth
                mnemonicText = ""
            }
            if elementName == "row" {
                rowDepth = depth
                rowCells = []
                return
            }
            if rowDepth != nil, let id = attributeDict["id"] {
                pendingDefinitions.append(
                    PendingDefinition(
                        depth: depth,
                        id: id,
                        formattedValue: attributeDict["fmt"]
                    )
                )
            }
            if let rowDepth, depth == rowDepth + 1 {
                pendingCell = PendingCell(
                    depth: depth,
                    reference: attributeDict["ref"],
                    formattedValue: attributeDict["fmt"]
                )
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if mnemonicDepth == depth {
                mnemonicText += string
            }
            if pendingCell?.depth == depth {
                pendingCell?.rawValue += string
            }
            if pendingDefinitions.last?.depth == depth {
                pendingDefinitions[pendingDefinitions.count - 1].rawValue += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if mnemonicDepth == depth, elementName == "mnemonic" {
                let mnemonic = mnemonicText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if mnemonic.isEmpty {
                    failure = .malformedXML
                    parser.abortParsing()
                } else {
                    columns.append(mnemonic)
                }
                mnemonicDepth = nil
            }

            if let definition = pendingDefinitions.last,
               definition.depth == depth {
                definitions[definition.id] = XctraceCell(
                    rawValue: definition.rawValue,
                    formattedValue: definition.formattedValue
                )
                pendingDefinitions.removeLast()
            }

            if let cell = pendingCell, cell.depth == depth {
                if elementName == "sentinel" {
                    rowCells.append(nil)
                } else if let reference = cell.reference {
                    guard let resolved = definitions[reference] else {
                        failure = .unresolvedReference
                        parser.abortParsing()
                        depth -= 1
                        return
                    }
                    rowCells.append(resolved)
                } else {
                    let value = XctraceCell(
                        rawValue: cell.rawValue,
                        formattedValue: cell.formattedValue
                    )
                    rowCells.append(value)
                }
                pendingCell = nil
            }

            if elementName == "row", rowDepth == depth {
                guard rowCells.count == columns.count else {
                    failure = .columnCountMismatch
                    parser.abortParsing()
                    depth -= 1
                    return
                }
                rows.append(
                    Dictionary(
                        uniqueKeysWithValues: zip(columns, rowCells)
                    )
                )
                rowDepth = nil
                rowCells = []
            }
            depth -= 1
        }

        func parser(
            _ parser: XMLParser,
            parseErrorOccurred parseError: Error
        ) {
            if failure == nil {
                failure = .malformedXML
            }
        }
    }
}
