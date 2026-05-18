//
//  PropertyTableView.swift
//  PortScope
//

import SwiftUI

struct PropertyTableView: View {
    let node: TBNode

    @State private var search = ""
    @State private var expandedRows: Set<String> = []

    private var filteredKeys: [String] {
        guard !search.isEmpty else { return node.propertyOrder }
        let q = search.lowercased()
        return node.propertyOrder.filter { key in
            if key.lowercased().contains(q) { return true }
            if let v = node.properties[key] {
                return v.display.lowercased().contains(q)
            }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Raw IORegistry Properties").font(.headline)
                Spacer()
                if let path = node.registryPath {
                    Button {
                        copyToPasteboard(path)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help(path)
                }
            }

            TextField("Filter…", text: $search)
                .textFieldStyle(.roundedBorder)

            VStack(spacing: 0) {
                ForEach(filteredKeys, id: \.self) { key in
                    if let value = node.properties[key] {
                        PropertyRow(key: key,
                                    value: value,
                                    isExpanded: expandedRows.contains(key),
                                    toggle: {
                                        if expandedRows.contains(key) { expandedRows.remove(key) }
                                        else { expandedRows.insert(key) }
                                    })
                        Divider()
                    }
                }
            }
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if filteredKeys.isEmpty {
                Text("No properties match \"\(search)\"")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }

            Text("\(node.propertyOrder.count) propert\(node.propertyOrder.count == 1 ? "y" : "ies")")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

private struct PropertyRow: View {
    let key: String
    let value: IORegValue
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if isCollapsible {
                    Button {
                        toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12)
                }
                Text(key)
                    .font(.callout.monospaced())
                    .frame(width: 240, alignment: .leading)
                Text(formattedSingleLine)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .lineLimit(isExpanded ? nil : 1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if isExpanded {
                Group {
                    switch value {
                    case .data(let d):
                        HexDumpView(data: d)
                            .padding(.leading, 32).padding(.bottom, 8)
                    case .array(let arr):
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(arr.enumerated()), id: \.offset) { _, v in
                                Text(v.display)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.leading, 32).padding(.bottom, 8)
                    case .dictionary(let kv):
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(kv.enumerated()), id: \.offset) { _, pair in
                                HStack(alignment: .top) {
                                    Text(pair.0)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 180, alignment: .leading)
                                    Text(pair.1.display)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.leading, 32).padding(.bottom, 8)
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var isCollapsible: Bool {
        switch value {
        case .data(let d): return d.count > 0
        case .array(let a): return !a.isEmpty
        case .dictionary(let d): return !d.isEmpty
        default: return false
        }
    }

    private var formattedSingleLine: String {
        return TBNode.formatValue(key, value)
    }
}

/// Compact hex dump for `Data` values like DROM / FW Counters.
struct HexDumpView: View {
    let data: Data
    private let bytesPerRow = 16

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 12) {
                        Text(String(format: "%04X", row * bytesPerRow))
                            .foregroundStyle(.secondary)
                        Text(hexBytes(forRow: row))
                        Text(asciiBytes(forRow: row))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .frame(maxHeight: 240)
        .padding(8)
        .background(.black.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var rowCount: Int { (data.count + bytesPerRow - 1) / bytesPerRow }

    private func hexBytes(forRow row: Int) -> String {
        let start = row * bytesPerRow
        let end = min(start + bytesPerRow, data.count)
        let slice = data[start..<end]
        var parts: [String] = []
        parts.reserveCapacity(bytesPerRow)
        for b in slice { parts.append(String(format: "%02x", b)) }
        while parts.count < bytesPerRow { parts.append("  ") }
        return parts.joined(separator: " ")
    }

    private func asciiBytes(forRow row: Int) -> String {
        let start = row * bytesPerRow
        let end = min(start + bytesPerRow, data.count)
        let slice = data[start..<end]
        var s = ""
        for b in slice {
            if b >= 0x20 && b < 0x7F {
                s.append(Character(UnicodeScalar(b)))
            } else {
                s.append(".")
            }
        }
        return s
    }
}
