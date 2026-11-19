import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
    pi.on("before_provider_request", (event, context) => {
        if (context.model?.provider === "ollama" && context.model.api === "openai-completions"
            && typeof event.payload === "object" && event.payload !== null) {
            // Pi may omit the effort when thinking is off. Ollama then uses the model default.
            return { ...event.payload, reasoning: { effort: "none" } };
        }
    });
}
