import Foundation

/// Representative JSON Canvas 1.0 fixtures for the deterministic scene-model
/// and geometry tests. Each fixture is a complete canvas document exercising
/// the spec surface the reviewed package must render.
enum JSONCanvasFixtures {
    /// Two text nodes + one edge with implicit sides/ends (the JSON Canvas
    /// defaults: fromEnd=none, toEnd=arrow, automatic sides).
    static let twoNodes: String = """
    {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":100,"height":50,"text":"First"},
              {"id":"b","type":"text","x":200,"y":0,"width":100,"height":50,"text":"Second"}],
     "edges":[{"id":"e","fromNode":"a","toNode":"b"}]}
    """

    /// Negative coordinates + widely separated nodes (bounds span negatives).
    static let negativeAndWide: String = """
    {"nodes":[{"id":"neg","type":"text","x":-300,"y":-200,"width":120,"height":60,"text":"Neg"},
              {"id":"far","type":"text","x":1800,"y":400,"width":160,"height":80,"text":"Far"}],
     "edges":[{"id":"e","fromNode":"neg","toNode":"far","fromSide":"right","toSide":"left"}]}
    """

    /// Multiline + long Markdown text (paragraphs, newlines, emphasis).
    static let multilineText: String = """
    {"nodes":[{"id":"note","type":"text","x":10,"y":10,"width":180,"height":90,"text":"**First line**\\n\\nSecond paragraph with *emphasis* and `code`."}],
     "edges":[]}
    """

    /// Text, file, link, and group nodes in overlapping z-order (first node
    /// lowest, last node highest). Group contains a labeled background color.
    static let mixedTypesZOrder: String = """
    {"nodes":[{"id":"text1","type":"text","x":0,"y":0,"width":100,"height":50,"text":"T"},
              {"id":"file1","type":"file","x":40,"y":20,"width":100,"height":60,"file":"diagram.png"},
              {"id":"link1","type":"link","x":80,"y":40,"width":100,"height":50,"url":"https://example.com"},
              {"id":"group1","type":"group","x":20,"y":10,"width":200,"height":120,"label":"Group","background":"#25c2a0"}],
     "edges":[]}
    """

    /// All preset colors (1..6) + hex colors on nodes and edges.
    static let allColors: String = """
    {"nodes":[{"id":"c1","type":"text","x":0,"y":0,"width":80,"height":40,"text":"1","color":"1"},
              {"id":"c2","type":"text","x":100,"y":0,"width":80,"height":40,"text":"2","color":"2"},
              {"id":"c3","type":"text","x":200,"y":0,"width":80,"height":40,"text":"3","color":"3"},
              {"id":"c4","type":"text","x":300,"y":0,"width":80,"height":40,"text":"4","color":"4"},
              {"id":"c5","type":"text","x":400,"y":0,"width":80,"height":40,"text":"5","color":"5"},
              {"id":"c6","type":"text","x":500,"y":0,"width":80,"height":40,"text":"6","color":"6"},
              {"id":"hx","type":"text","x":600,"y":0,"width":80,"height":40,"text":"hex","color":"#ff8800"}],
     "edges":[{"id":"e","fromNode":"c1","toNode":"c6","color":"4","label":"colored"}]}
    """

    /// Explicit + automatic sides, all fromEnd/toEnd combinations.
    static let sideAndEndCombinations: String = """
    {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":100,"height":50,"text":"A"},
              {"id":"b","type":"text","x":200,"y":0,"width":100,"height":50,"text":"B"},
              {"id":"c","type":"text","x":0,"y":200,"width":100,"height":50,"text":"C"}],
     "edges":[{"id":"e1","fromNode":"a","toNode":"b","fromSide":"right","toSide":"left","fromEnd":"none","toEnd":"arrow"},
              {"id":"e2","fromNode":"b","toNode":"c","fromSide":"bottom","toSide":"top","fromEnd":"arrow","toEnd":"none"},
              {"id":"e3","fromNode":"a","toNode":"b","fromEnd":"none","toEnd":"none"}]}
    """

    /// Straight, horizontal, vertical, diagonal, and overlapping-node edges.
    static let edgeShapes: String = """
    {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":100,"height":50,"text":"A"},
              {"id":"b","type":"text","x":300,"y":0,"width":100,"height":50,"text":"B"},
              {"id":"c","type":"text","x":0,"y":300,"width":100,"height":50,"text":"C"},
              {"id":"d","type":"text","x":150,"y":150,"width":120,"height":80,"text":"D"}],
     "edges":[{"id":"h","fromNode":"a","toNode":"b","fromSide":"right","toSide":"left"},
              {"id":"v","fromNode":"a","toNode":"c","fromSide":"bottom","toSide":"top"},
              {"id":"diag","fromNode":"a","toNode":"d","fromSide":"right","toSide":"left"},
              {"id":"overlap","fromNode":"d","toNode":"b","fromSide":"right","toSide":"left"}]}
    """

    /// Edge labels on curved paths.
    static let edgeLabels: String = """
    {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":100,"height":50,"text":"A"},
              {"id":"b","type":"text","x":250,"y":60,"width":100,"height":50,"text":"B"}],
     "edges":[{"id":"e","fromNode":"a","toNode":"b","label":"connection","fromSide":"right","toSide":"left"}]}
    """

    /// Image file nodes (PNG/JPEG/GIF/SVG/WebP references) + group
    /// backgrounds with cover/ratio/repeat.
    static let imageNodes: String = """
    {"nodes":[{"id":"png","type":"file","x":0,"y":0,"width":100,"height":80,"file":"img/png.png"},
              {"id":"jpg","type":"file","x":120,"y":0,"width":100,"height":80,"file":"img/jpg.jpg"},
              {"id":"gif","type":"file","x":240,"y":0,"width":100,"height":80,"file":"img/gif.gif"},
              {"id":"svg","type":"file","x":360,"y":0,"width":100,"height":80,"file":"img/svg.svg"},
              {"id":"webp","type":"file","x":480,"y":0,"width":100,"height":80,"file":"img/webp.webp"},
              {"id":"grp","type":"group","x":0,"y":120,"width":300,"height":160,"label":"Cover","background":"img/bg.png","backgroundStyle":"cover"},
              {"id":"grp2","type":"group","x":320,"y":120,"width":300,"height":160,"label":"Ratio","background":"img/bg.png","backgroundStyle":"ratio"},
              {"id":"grp3","type":"group","x":640,"y":120,"width":300,"height":160,"label":"Repeat","background":"img/bg.png","backgroundStyle":"repeat"}],
     "edges":[]}
    """

    /// Missing/unavailable/oversized attachments (must fall back at admission;
    /// the references themselves are parse-valid).
    static let unavailableAttachments: String = """
    {"nodes":[{"id":"missing","type":"file","x":0,"y":0,"width":100,"height":80,"file":"missing.png"},
              {"id":"unsupported","type":"file","x":120,"y":0,"width":100,"height":80,"file":"notes.txt"}],
     "edges":[]}
    """

    /// Parse-invalid file references (traversal / scheme) — the strict parser
    /// rejects the whole canvas.
    static let invalidFileReferences: String = """
    {"nodes":[{"id":"traversal","type":"file","x":0,"y":0,"width":100,"height":80,"file":"../secret.png"},
              {"id":"scheme","type":"file","x":120,"y":0,"width":100,"height":80,"file":"https:evil.png"}],
     "edges":[]}
    """

    /// Link/file nodes with typed internal navigation + external URLs.
    static let navigationNodes: String = """
    {"nodes":[{"id":"pageLink","type":"link","x":0,"y":0,"width":140,"height":50,"url":"[[page:01HXXXXXXXXXXXXXXXXXXXXXXX]]"},
              {"id":"sourceLink","type":"link","x":160,"y":0,"width":140,"height":50,"url":"[[source:01HXXXXXXXXXXXXXXXXXXXXXXX]]"},
              {"id":"external","type":"link","x":320,"y":0,"width":140,"height":50,"url":"https://example.com"},
              {"id":"fileNode","type":"file","x":480,"y":0,"width":140,"height":50,"file":"report.md"}],
     "edges":[]}
    """

    /// The real-world Testbed fixture ("JSON Canvas — File and Link Nodes"):
    /// file nodes with spaced names and a subpath, plus external link nodes
    /// and one side-labeled edge. Regressed in 1.1.0 when the subpath
    /// validator rejected its own leading '#'.
    static let fileAndLinkNodes: String = """
    {"nodes":[{"id":"2000000000000001","type":"file","x":0,"y":0,"width":360,"height":240,"file":"JSON Canvas","subpath":"#JSON Canvas Testbed","color":"5"},
              {"id":"2000000000000002","type":"file","x":440,"y":0,"width":300,"height":220,"file":"SVG","color":"#f59e0b"},
              {"id":"2000000000000003","type":"link","x":0,"y":320,"width":360,"height":160,"url":"https://jsoncanvas.org/spec/1.0/","color":"2"},
              {"id":"2000000000000004","type":"link","x":440,"y":320,"width":300,"height":160,"url":"https://obsidian.md","color":"#7c3aed"}],
     "edges":[{"id":"2e00000000000001","fromNode":"2000000000000001","fromSide":"right","toNode":"2000000000000003","toSide":"top","toEnd":"arrow","label":"file to specification"}]}
    """

    /// The Testbed "Edges and Endpoints" fixture: every edge side, both
    /// endpoint shapes, labels, preset + hex colors, and one default edge.
    static let edgesAndEndpoints: String = """
    {"nodes":[{"id":"4000000000000001","type":"text","x":0,"y":180,"width":220,"height":100,"text":"Left"},
              {"id":"4000000000000002","type":"text","x":340,"y":180,"width":240,"height":100,"color":"3","text":"Center"},
              {"id":"4000000000000003","type":"text","x":700,"y":180,"width":220,"height":100,"text":"Right"},
              {"id":"4000000000000004","type":"text","x":340,"y":0,"width":240,"height":100,"text":"Top"},
              {"id":"4000000000000005","type":"text","x":340,"y":360,"width":240,"height":100,"text":"Bottom"}],
     "edges":[{"id":"4e00000000000001","fromNode":"4000000000000001","fromSide":"right","fromEnd":"none","toNode":"4000000000000002","toSide":"left","toEnd":"arrow","color":"1","label":"right to left"},
              {"id":"4e00000000000002","fromNode":"4000000000000004","fromSide":"bottom","fromEnd":"arrow","toNode":"4000000000000002","toSide":"top","toEnd":"none","color":"2","label":"bottom to top"},
              {"id":"4e00000000000003","fromNode":"4000000000000002","fromSide":"bottom","fromEnd":"none","toNode":"4000000000000005","toSide":"top","toEnd":"arrow","color":"#059669","label":"downward"},
              {"id":"4e00000000000004","fromNode":"4000000000000002","fromSide":"right","fromEnd":"arrow","toNode":"4000000000000003","toSide":"left","toEnd":"arrow","color":"6","label":"two arrows"},
              {"id":"4e00000000000005","fromNode":"4000000000000001","toNode":"4000000000000005"}]}
    """
}
