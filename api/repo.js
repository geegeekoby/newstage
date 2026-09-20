/**
 * Serves the parts of the repository that have to name their own host.
 *
 * A package's icon and depiction have to be absolute URLs, and the deployment's
 * domain is not known when the index is generated, so those three files are
 * composed per request from api/package-index.json instead of being written out
 * by tools/make_repo.py. Everything else in the repo (Release, the .deb, the
 * artwork) is static and served straight from public/.
 *
 * vercel.json routes /Packages, /Packages.gz, /depiction.json and
 * /sileo-featured.json here.
 */

const zlib = require("zlib");
const index = require("./package-index.json");

const TINT = "#0A84FF";

function baseURL(req) {
  // Hosting always sets the forwarded headers; the fallbacks are for running the
  // handler behind tools/serve_repo.mjs.
  const proto =
    req.headers["x-forwarded-proto"] || (req.socket && req.socket.encrypted ? "https" : "http");
  const host = req.headers["x-forwarded-host"] || req.headers.host;
  return `${proto}://${host}`;
}

function packages(base) {
  return (
    index.stanza +
    `Icon: ${base}/assets/icon.png\n` +
    `Depiction: ${base}/depiction.json\n` +
    `SileoDepiction: ${base}/depiction.json\n`
  );
}

function depiction(base) {
  const details = [
    {
      class: "DepictionSubheaderView",
      title: "Stage Manager Reimagined for iPhone",
    },
    {
      class: "DepictionMarkdownView",
      markdown:
        "Pull up from the bottom-right corner of any app and a second app slides onto " +
        "the stage. Leave it floating over what you were doing, or push it down into " +
        "Split View and run both at once. Hold an app in the picker to send it " +
        "fullscreen instead, flick the stage away when you are done.\n\n" +
        "A rootless rebuild of the tweak, targeting iOS 14 through 16 on arm64 " +
        "devices. Tested on an iPhone 14 Pro Max running iOS 16.5.1 with NathanLR.",
      useRawFormat: false,
    },
    { class: "DepictionSeparatorView" },
    { class: "DepictionHeaderView", title: "What you get" },
    {
      class: "DepictionMarkdownView",
      markdown:
        "- Corner pull gesture with the app behind shrinking away as you drag\n" +
        "- Floating overlay and Split View, switchable with a drag on the stage\n" +
        "- App picker with search, recents, pinned rows and now-playing marks\n" +
        "- Hold a plate to launch fullscreen, flick down to put the stage away\n" +
        "- Per-app launch mode, scale, rotation and keyboard handling\n" +
        "- Auto kill, first-run walkthrough and a full Settings pane",
      useRawFormat: false,
    },
    { class: "DepictionSeparatorView" },
    { class: "DepictionHeaderView", title: "Before you install" },
    {
      class: "DepictionMarkdownView",
      markdown:
        "Rootless only: it installs under /var/jb and needs ElleKit or Substitute. " +
        "Respring after installing, then open Settings › Dynamic Stage to choose " +
        "which apps appear on the stage.",
      useRawFormat: false,
    },
    { class: "DepictionSeparatorView" },
    { class: "DepictionTableTextView", title: "Version", text: index.version },
    { class: "DepictionTableTextView", title: "Compatibility", text: "iOS 14.0 – 16.7" },
    { class: "DepictionTableTextView", title: "Architecture", text: "arm64 (rootless)" },
    {
      class: "DepictionTableButtonView",
      title: "Download .deb",
      action: `${base}/debs/${index.deb}`,
      openExternal: true,
    },
  ];

  return {
    minVersion: "0.1",
    headerImage: `${base}/assets/banner.png`,
    tintColor: TINT,
    tabs: [
      { class: "DepictionStackView", tabname: "Details", views: details },
      {
        class: "DepictionStackView",
        tabname: "Changelog",
        views: [
          { class: "DepictionHeaderView", title: index.version },
          {
            class: "DepictionMarkdownView",
            markdown:
              "- Rootless build for iOS 14 – 16, arm64\n" +
              "- Stage geometry, gestures and animations matched to the original\n" +
              "- iPad multitasking path for apps set to iPad launch mode\n" +
              "- Settings pane with per-app behaviour and pinned apps",
            useRawFormat: false,
          },
        ],
      },
    ],
  };
}

function featured(base) {
  return {
    class: "FeaturedBannersView",
    itemCornerRadius: 12,
    itemSize: "{263, 148}",
    itemTitleFontSize: 15,
    banners: [
      {
        title: index.name,
        package: index.package,
        url: `${base}/depiction.json`,
        image: `${base}/assets/banner.png`,
        hideShadow: false,
        displayText: true,
      },
    ],
  };
}

module.exports = (req, res) => {
  const base = baseURL(req);
  const file = (req.query && req.query.file) || "packages";

  res.setHeader("Access-Control-Allow-Origin", "*");
  // Never cached: a package manager that was handed a stale index will not offer
  // a version it does not know exists, and this repo ships one package whose
  // index costs nothing to rebuild.
  res.setHeader("Cache-Control", "no-store, max-age=0");

  switch (file) {
    case "packages":
      res.setHeader("Content-Type", "text/plain; charset=utf-8");
      return res.status(200).send(packages(base));

    case "packages.gz": {
      const body = zlib.gzipSync(Buffer.from(packages(base), "utf8"), { level: 9 });
      res.setHeader("Content-Type", "application/gzip");
      res.setHeader("Content-Length", String(body.length));
      return res.status(200).end(body);
    }

    case "depiction":
      res.setHeader("Content-Type", "application/json; charset=utf-8");
      return res.status(200).send(JSON.stringify(depiction(base)));

    case "featured":
      res.setHeader("Content-Type", "application/json; charset=utf-8");
      return res.status(200).send(JSON.stringify(featured(base)));

    default:
      return res.status(404).send("not found\n");
  }
};
