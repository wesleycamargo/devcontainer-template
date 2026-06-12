import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const projectName = process.env.AZURE_FOUNDRY_PROJECT_NAME;

  if (!projectName) {
    throw new Error("Missing AZURE_FOUNDRY_PROJECT_NAME environment variable.");
  }

  pi.registerProvider("azure-foundry-user", {
    baseUrl: `https://${projectName}.services.ai.azure.com/openai/v1`,
    api: "openai-responses",
    apiKey:
      "!az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv",
    authHeader: true,
    models: [
      {
        id: "gpt-5.3-codex",
        name: "gpt-5.3-codex",
        reasoning: true,
        input: ["text", "image"],
        contextWindow: 128000,
        maxTokens: 16384,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  });
}
