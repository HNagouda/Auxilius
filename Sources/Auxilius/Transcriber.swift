import Foundation

/// Reads a photo of a handwritten page with Claude and returns it as Markdown with LaTeX and Mermaid.
enum Transcriber {
    // Reading a page needs little deliberation, and every second counts while someone waits.
    private static let effort = "low"
    // Re-runs a declined request on the model Anthropic recommends for that refusal category.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"
    private static let maxTokens = 16000

    private static let systemPrompt = """
        You transcribe a photo of a page that a student is writing on, usually while working through \
        maths, physics or electronics exercises. A chat assistant will read your transcription instead \
        of the page, so it must carry everything the page says and nothing else.

        Format:
        - Output only the transcription, as GitHub-flavoured Markdown. No preamble and no commentary.
        - Write all mathematics in LaTeX: $...$ inline, $$...$$ for an equation on its own line.
        - Keep the order and line structure of the page. When the page is split into separate problems \
        or regions (ruled off, boxed, side by side), give each one a short ### heading such as \
        ### Circuit 1, and keep everything written in that region under it.
        - Use lists and tables only where the page itself has them.
        - Annotations that sit apart from the main working (arrows with notes, side remarks, or writing \
        in a different ink colour) go in italics next to what they point at, for example \
        *(red, arrow towards the source: 8 V drop)*.

        Diagrams:
        - Draw circuits, flowcharts, trees, state machines and other node-and-line diagrams as a fenced \
        ```mermaid block, using `flowchart LR`.
        - For a circuit, every component is a node labelled with its name and value, for example \
        S1["2 V source"], R1["R1 2 kΩ"], C1["C1 100 µF"], L1["L1 2 H"]. Every wire is an edge. Put \
        labelled junctions, node voltages and currents on the edges or as their own small nodes, with \
        the values written on the page.
        - Mermaid labels are plain text: no LaTeX inside them, and wrap every label in double quotes.
        - Under each diagram, add one line in square brackets saying what it shows, for example \
        [Series RC loop: 2 V source, 2 kΩ resistor, 100 µF capacitor with V_C = 5 V].
        - Graphs, plots and sketches that are not node-and-line diagrams get only the square-bracket \
        line, with the axes, labelled points and values.

        Accuracy:
        - Leave out anything crossed out. Write [illegible] for anything you cannot read.
        - Ignore hands, pens and anything off the page. If no handwriting is visible, output nothing.
        - Transcribe exactly what is written, mistakes included. Do not solve, correct or complete anything.
        """

    static func transcribe(jpeg: Data, previous: String, model: ClaudeModel, apiKey: String) async throws -> String {
        var request = AnthropicAPI.request("messages", apiKey: apiKey, beta: model.supportsServerFallback ? fallbackBeta : nil)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body(jpeg: jpeg, previous: previous, model: model))

        let response = try await AnthropicAPI.send(request)
        guard response["stop_reason"] as? String != "refusal" else { throw APIError.refused }

        let blocks = response["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func body(jpeg: Data, previous: String, model: ClaudeModel) -> [String: Any] {
        // The earlier transcription keeps unchanged lines worded the same, so the text does not churn.
        let instruction = previous.isEmpty
            ? "Transcribe this page."
            : "Transcribe this page. Your transcription of an earlier moment is below; keep lines that have not changed exactly as they are.\n\n<earlier_transcription>\n\(previous)\n</earlier_transcription>"
        let image: [String: Any] = [
            "type": "image",
            "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
        ]

        var body: [String: Any] = [
            "model": model.id,
            // Older models cap output lower than a full page could need.
            "max_tokens": min(maxTokens, model.maxOutputTokens),
            "system": systemPrompt,
            "messages": [["role": "user", "content": [image, ["type": "text", "text": instruction]]]],
        ]
        if model.supportsLowEffort {
            body["output_config"] = ["effort": effort]
        }
        if model.supportsServerFallback {
            body["fallbacks"] = "default"
        }
        return body
    }
}
