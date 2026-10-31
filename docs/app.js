const repository = "Church54711/obs-game-replay-automation";
const apiUrl = `https://api.github.com/repos/${repository}/releases/latest`;
const statusElement = document.querySelector("#release-status");
const downloadButton = document.querySelector("#download-button");

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return null;
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
}

async function loadLatestRelease() {
  try {
    const response = await fetch(apiUrl, {
      headers: { Accept: "application/vnd.github+json" }
    });
    if (!response.ok) throw new Error(`GitHub returned ${response.status}`);

    const release = await response.json();
    const assets = Array.isArray(release.assets) ? release.assets : [];
    const setup = assets.find((candidate) => /^obs-game-replay-automation-\d+\.\d+\.\d+-setup\.exe$/.test(candidate.name));
    const asset = setup || assets.find((candidate) => candidate.name === "obs-game-replay-automation-latest.zip");

    if (asset?.browser_download_url) {
      downloadButton.href = asset.browser_download_url;
      downloadButton.textContent = setup ? "Download Windows installer" : "Download ZIP package";
    }

    const version = String(release.tag_name || "").replace(/^v/, "");
    const date = release.published_at
      ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(new Date(release.published_at))
      : null;
    const size = formatBytes(asset?.size);
    const details = [version ? `Version ${version}` : null, date, size].filter(Boolean);
    statusElement.textContent = details.length ? details.join(" · ") : "Latest stable release available on GitHub";
  } catch (error) {
    statusElement.textContent = "Latest stable download · Release details available on GitHub";
  }
}

loadLatestRelease();
