// Parity + speed check for the Swift engine. swiftc -O tools/gptcheck/main.swift Sources/Island/TinyGPT.swift
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "pup")
guard let g = TinyGPT(json: dir.appendingPathComponent("pup.json"), bin: dir.appendingPathComponent("pup.bin")) else { print("load failed"); exit(1) }
let prompts = ["greet|morning", "music|Tum Hi Ho", "hungry", "chat|do you love me?"]
for p in prompts { print("GREEDY \(p) -> \(g.generate(p, temperature: 0))") }
let t0 = Date(); var n = 0
for _ in 0..<20 { n += g.generate("music|Golden Hour").count }
let dt = Date().timeIntervalSince(t0)
print(String(format: "speed: %.1f ms per line (%d chars avg)", dt / 20 * 1000, n / 20))
