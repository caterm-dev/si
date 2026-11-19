import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
    pi.on("before_provider_request", (event, context) => {
        if (context.model?.provider === "ollama" && context.model.api === "openai-completions"
            && typeof event.payload === "object" && event.payload !== null) {
            return { ...event.payload, reasoning: { effort: "low" } };
        }
    });
}
