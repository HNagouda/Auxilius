import Foundation

/// Reads a photo of a handwritten page with Claude and returns it as Markdown with LaTeX, circuit JSON,
/// Mermaid, and sketch blocks that point at where each drawing sits in the photo.
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

        Circuits:
        - Write each circuit diagram as a fenced ```circuit block holding one JSON object. The app draws \
        it as a schematic for the student and turns it into a netlist for the chat assistant.
        - Trace the layout of the sketch onto a grid of integer points [x, y], with x to the right and y \
        downwards, so the drawing keeps the shape the student drew. Use 2 to 4 grid steps per component.
        - "parts" lists every component and wire. A two-terminal part runs "from" one point "to" another, \
        in a straight horizontal or vertical line. Types: wire, resistor, capacitor, inductor, battery, \
        voltage_source, current_source, diode (from anode to cathode), switch. For battery, voltage_source \
        and current_source, "to" is the + side, or the side the arrow points to. Give "name" (R1, C1, V1) \
        and "value" ("2 kΩ", "100 µF", "12 V") as written; put anything else written beside a component, \
        such as an initial voltage, in "note". A ground symbol is {"type": "ground", "at": [x, y]}.
        - Every corner and junction is a grid point where parts meet, so wires must meet the parts they \
        connect to at exactly the same point.
        - "nodes" names labelled points, for example {"at": [4, 0], "text": "A"}. "title" is a few words.
        - Example: {"title": "Series RC", "parts": [
          {"type": "battery", "name": "V1", "value": "2 V", "from": [0, 2], "to": [0, 0]},
          {"type": "resistor", "name": "R1", "value": "2 kΩ", "from": [0, 0], "to": [3, 0]},
          {"type": "capacitor", "name": "C1", "value": "100 µF", "note": "V_C = 5 V", "from": [3, 0], "to": [3, 2]},
          {"type": "wire", "from": [3, 2], "to": [0, 2]}]}
        - Under each circuit, add one line in square brackets saying what it is, for example \
        [Series RC loop: 2 V source, 2 kΩ resistor, 100 µF capacitor with V_C = 5 V].

        Other diagrams:
        - Any other diagram made of nodes joined by lines or arrows goes in a fenced ```mermaid block: \
        flowcharts, trees, state machines, automata, networks, ER diagrams, and graphs such as resource \
        allocation graphs. Use `flowchart TB` or `flowchart LR`, whichever matches the sketch.
        - Match the drawn shapes: a circle or oval is a rounded box ("P1"), a box is ["R1"], a diamond is \
        {"x > 0"}. Do not use (( )) circles. Put \
        what is drawn inside a shape in its label, for example ["R1 (2 instances)"] for a box with two dots.
        - Keep every arrow and its direction, labelled edges as -->|"A"|, plain lines as ---, and dashed \
        lines as -.-> or -.->|"label"|. If an arrow's direction is unclear, draw your best reading and say \
        so in the square-bracket line.
        - Mermaid labels are plain text: no LaTeX, and every label in double quotes.
        - Under each diagram, add one line in square brackets saying what it shows.

        Original sketches:
        - Directly after every diagram (circuit or Mermaid), before its square-bracket line, add a fenced \
        ```sketch block holding one JSON object, \
        {"box": [left, top, right, bottom]}, giving where the drawing sits in the photo as fractions of the \
        image width and height, with a little margin. The app shows that crop of the photo, so the student \
        can check your diagram against what they drew.
        - Plots, graphs with axes and free sketches that are neither circuits nor node-and-line diagrams \
        get only a ```sketch block and a square-bracket line with the axes, labelled points and values.

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
