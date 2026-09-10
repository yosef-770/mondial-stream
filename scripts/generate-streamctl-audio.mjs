/**
 * יוצר קבצי WAV לתפריט streamctl (עברית, Gemini Charon).
 * הרצה: node /srv/mondial-stream/scripts/generate-streamctl-audio.mjs
 */
import { execSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { GoogleGenAI } from "/srv/virtual-mail/node_modules/@google/genai/dist/node/index.mjs";

const __dir = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(__dir, "../freeswitch/sounds/he/streamctl");

const DEFAULT_MODELS = ["gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"];
const MAX_ATTEMPTS = 6;

function loadVirtualMailEnv() {
  const envPath = "/srv/virtual-mail/.env.local";
  for (const line of readFileSync(envPath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq <= 0) continue;
    const key = trimmed.slice(0, eq).trim();
    const val = trimmed.slice(eq + 1).trim();
    if (!process.env[key]) process.env[key] = val;
  }
}

function buildWavBuffer(pcmData, channels = 1, rate = 24000, sampleWidth = 2) {
  const byteRate = rate * channels * sampleWidth;
  const blockAlign = channels * sampleWidth;
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcmData.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(rate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(sampleWidth * 8, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcmData.length, 40);
  return Buffer.concat([header, pcmData]);
}

function decodeAudioData(data) {
  if (Buffer.isBuffer(data)) return data;
  if (typeof data === "string") return Buffer.from(data, "base64");
  return Buffer.from(data);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function synthesizeHebrewWav(text) {
  const apiKey = process.env.GEMINI_API_KEY?.trim();
  if (!apiKey) throw new Error("GEMINI_API_KEY חסר");

  const trimmed = text.trim().slice(0, 4800);
  if (!trimmed) throw new Error("tts_empty_text");

  const voiceName = process.env.GEMINI_TTS_VOICE?.trim() || "Charon";
  const languageCode = process.env.GEMINI_TTS_LANGUAGE?.trim() || "he-IL";
  const ai = new GoogleGenAI({ apiKey });
  const prompts = [
    `TTS the following Hebrew text exactly as written: ${trimmed}`,
    `Read the following text aloud in Hebrew: ${trimmed}`,
  ];

  let lastReason = "unknown";
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
    const model = DEFAULT_MODELS[Math.min(attempt, DEFAULT_MODELS.length - 1)];
    const prompt = prompts[attempt % prompts.length];
    try {
      const response = await ai.models.generateContent({
        model,
        contents: [{ parts: [{ text: prompt }] }],
        config: {
          responseModalities: ["AUDIO"],
          speechConfig: {
            languageCode,
            voiceConfig: { prebuiltVoiceConfig: { voiceName } },
          },
        },
      });

      const candidate = response.candidates?.[0];
      const data = candidate?.content?.parts?.[0]?.inlineData?.data;
      lastReason = candidate?.finishReason || "unknown";
      if (!data) {
        await sleep(1500 * (attempt + 1));
        continue;
      }

      const pcmBuffer = decodeAudioData(data);
      if (pcmBuffer.length === 0) throw new Error("gemini_empty_audio");
      return buildWavBuffer(pcmBuffer);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (attempt < MAX_ATTEMPTS - 1) {
        await sleep(message.includes("429") ? 5000 * (attempt + 1) : 1500 * (attempt + 1));
        continue;
      }
      throw error;
    }
  }
  throw new Error(`gemini_tts_failed:${lastReason}`);
}

function toTelephonyWav(inputPath, outputPath) {
  execSync(
    `ffmpeg -y -hide_banner -loglevel error -i "${inputPath}" -ar 8000 -ac 1 -acodec pcm_s16le "${outputPath}"`,
    { stdio: "inherit" },
  );
}

async function writeClip(name, text) {
  const rawPath = join(OUT_DIR, `${name}-24k.wav`);
  const outPath = join(OUT_DIR, `${name}.wav`);
  console.log(`[generate] ${name}...`);
  writeFileSync(rawPath, await synthesizeHebrewWav(text));
  toTelephonyWav(rawPath, outPath);
  execSync(`rm -f "${rawPath}"`);
  console.log(`[generate] wrote ${outPath}`);
}

loadVirtualMailEnv();
mkdirSync(OUT_DIR, { recursive: true });

await writeClip(
  "menu",
  `שלום. תפריט שליטה בשידורים.
להדלקת כל השידורים, הקש 1.
לכיבוי כל השידורים, הקש 2.
להדלקת רשת בית, הקש 3.
להדלקת כאן 11, הקש 4.
לכיבוי רשת בית, הקש 5.
לכיבוי כאן 11, הקש 6.`,
);
await writeClip("ok", "הפעולה בוצעה בהצלחה.");
await writeClip("err", "בחירה לא תקינה, או שהפעולה נכשלה.");
console.log("[generate] done.");
