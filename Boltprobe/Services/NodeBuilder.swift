//
//  NodeBuilder.swift
//  Boltprobe
//
//  Generic IORegistry → TBNode tree builder. Used by both ThunderboltScanner
//  and USBScanner so they share classification, label, and ordering logic.
//

import Foundation
import IOKit

enum NodeBuilder {
    /// Recursively build a TBNode tree from an IORegistry entry.
    /// Children are sorted by Port Number (when present), then title.
    static func build(from entry: io_registry_entry_t) -> TBNode? {
        guard let cls = IORegBridge.className(of: entry),
              let id = IORegBridge.entryID(of: entry) else { return nil }

        let name = IORegBridge.name(of: entry) ?? cls
        let location = IORegBridge.location(of: entry)
        let props = IORegBridge.properties(of: entry)
        let rawKind = NodeFormatter.classify(cls)
        let kind = NodeFormatter.refineKind(rawKind, props: props)
        let path = IORegBridge.path(of: entry)

        var childNodes: [TBNode] = []
        for child in IORegBridge.children(of: entry) {
            if let n = build(from: child) {
                childNodes.append(n)
            }
            IOObjectRelease(child)
        }
        childNodes.sort { lhs, rhs in
            let lp = lhs.properties["Port Number"]?.asUInt ?? UInt64.max
            let rp = rhs.properties["Port Number"]?.asUInt ?? UInt64.max
            if lp != rp { return lp < rp }
            return lhs.title < rhs.title
        }

        let (title, subtitle) = NodeFormatter.makeLabels(
            class: cls, name: name, location: location, kind: kind, props: props
        )
        let ordered = NodeFormatter.preferredOrder(for: kind, keys: Array(props.keys))

        return TBNode(
            id: TBNodeID(raw: id),
            kind: kind,
            title: title,
            subtitle: subtitle,
            className: cls,
            properties: props,
            propertyOrder: ordered,
            children: childNodes,
            registryPath: path
        )
    }
}
