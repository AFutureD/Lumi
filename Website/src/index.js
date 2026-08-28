// /download — 302 to the latest release's dmg.
//
// The GitHub lookup lives server-side so the token (optional, raises the API
// rate limit) never reaches the page. The resolved URL is cached at the edge
// for a few minutes; on any failure the response falls back to the releases
// page so the button always lands somewhere useful.

const RELEASES_PAGE = 'https://github.com/AFutureD/Lumi/releases/latest';
const API_LATEST = 'https://api.github.com/repos/AFutureD/Lumi/releases/latest';
const CACHE_KEY = 'https://lumi.huanan.app/__internal/latest-dmg-url';
const CACHE_TTL_SECONDS = 300;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname !== '/download') return env.ASSETS.fetch(request);

    const location = await resolveDmgUrl(env, ctx);
    return new Response(null, {
      status: 302,
      // no-store: the edge cache already throttles GitHub lookups; a browser
      // must not pin an old dmg URL past the next release.
      headers: { Location: location, 'Cache-Control': 'no-store' },
    });
  },
};

async function resolveDmgUrl(env, ctx) {
  // A broken edge cache must degrade to a fresh lookup, never a 500.
  const cache = caches.default;
  const cached = await cache
    .match(CACHE_KEY)
    .then((res) => (res ? res.text() : null))
    .catch((err) => {
      console.warn(`download cache read failed err=${err}`);
      return null;
    });
  if (cached) return cached;

  try {
    const headers = {
      'User-Agent': 'lumi-website',
      Accept: 'application/vnd.github+json',
    };
    if (env.GITHUB_TOKEN) headers.Authorization = `Bearer ${env.GITHUB_TOKEN}`;

    const res = await fetch(API_LATEST, {
      headers,
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) throw new Error(`github api status=${res.status}`);

    const release = await res.json();
    const dmg = (release.assets ?? []).find((a) => a.name.endsWith('.dmg'));
    if (!dmg) throw new Error(`no dmg asset tag=${release.tag_name}`);

    ctx.waitUntil(
      cache
        .put(
          CACHE_KEY,
          new Response(dmg.browser_download_url, {
            headers: { 'Cache-Control': `max-age=${CACHE_TTL_SECONDS}` },
          }),
        )
        .catch((err) => console.warn(`download cache write failed err=${err}`)),
    );
    console.log(`download resolved tag=${release.tag_name} asset=${dmg.name}`);
    return dmg.browser_download_url;
  } catch (err) {
    console.warn(`download resolve failed, falling back to releases page err=${err}`);
    return RELEASES_PAGE;
  }
}
