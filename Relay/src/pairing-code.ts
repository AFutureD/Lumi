/** Crockford Base32: digits plus letters without the look-alikes I, L, O, U. */
export const PAIRING_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const PAIRING_CODE_LENGTH = 6;

const ALPHABET_PATTERN = new RegExp(`^[${PAIRING_CODE_ALPHABET}]{${PAIRING_CODE_LENGTH}}$`, "u");

/** Six symbols of five random bits each: 30 bits of entropy per code. */
export function generatePairingCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(PAIRING_CODE_LENGTH));
  let code = "";
  for (const byte of bytes) {
    const symbol = PAIRING_CODE_ALPHABET[byte & 0b11111];
    if (symbol === undefined) throw new Error("Pairing code alphabet is shorter than 32 symbols.");
    code += symbol;
  }
  return code;
}

/**
 * Canonical form of a typed or scanned code: uppercase, no spaces or hyphens,
 * look-alike letters folded onto the symbol they were mistaken for.
 * Returns null when the result is not exactly six alphabet symbols.
 */
export function normalizePairingCode(input: string): string | null {
  const folded = input
    .toUpperCase()
    .replaceAll(/[\s-]/gu, "")
    .replaceAll("O", "0")
    .replaceAll("I", "1")
    .replaceAll("L", "1")
    .replaceAll("U", "V");
  return ALPHABET_PATTERN.test(folded) ? folded : null;
}
