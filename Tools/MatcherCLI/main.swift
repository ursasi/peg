import AppKit

// Usage: matcher <first.png> <second.png> [more.png ...]
// Prints the matcher's decision and scores for each consecutive pair.
let paths = Array(CommandLine.arguments.dropFirst())
guard paths.count >= 2 else {
    print("usage: matcher a.png b.png [c.png ...]")
    exit(2)
}

func load(_ path: String) -> ScrollFrame? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return ScrollFrame(image: cg)
}

var previous = load(paths[0])
for path in paths.dropFirst() {
    guard let current = load(path) else { print("cannot read \(path)"); exit(1) }
    guard let prev = previous else { previous = current; continue }
    print("\(path.split(separator: "/").last ?? "?")  \(ScrollMatcher.diagnose(prev, current))")
    previous = current
}
