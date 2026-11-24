import type * as Preset from "@docusaurus/preset-classic";
import type { Config } from "@docusaurus/types";
import { themes as prismThemes } from "prism-react-renderer";

const repository = "https://github.com/izaccavalheiro/testor";

/**
 * The site is static. The only other origin it talks to is the Monoid analytics tracker
 * (production only); no fonts, no search service. Docusaurus inlines a small script that sets
 * the colour mode before the page paints, hence 'unsafe-inline' for scripts. Production only: the development server needs a WebSocket.
 */
const ANALYTICS_ORIGIN = "https://api.monoid.website";

const CONTENT_SECURITY_POLICY = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-inline' ${ANALYTICS_ORIGIN}`,
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self' data:",
  `connect-src 'self' ${ANALYTICS_ORIGIN}`,
  "form-action 'none'",
  "frame-src 'none'",
  "object-src 'none'",
  "base-uri 'self'",
].join("; ");

const production = process.env["NODE_ENV"] === "production";

const config: Config = {
  title: "testor",
  tagline:
    "The free, open-source test orchestrator: run your suites on any machine over SSH and watch them live.",
  favicon: "img/logo.svg",

  url: "https://izaccavalheiro.github.io",
  baseUrl: "/testor/",
  organizationName: "izaccavalheiro",
  projectName: "testor",
  trailingSlash: false,

  onBrokenLinks: "throw",
  onBrokenAnchors: "throw",
  markdown: {
    // .md files are CommonMark, so the repository's own Markdown is used as it is
    // (`<home>` and `{...}` stay text); .mdx files may use components.
    format: "detect",
    hooks: { onBrokenMarkdownLinks: "throw" },
  },

  i18n: { defaultLocale: "en", locales: ["en"] },

  headTags: production
    ? [
        {
          tagName: "meta",
          attributes: { "http-equiv": "Content-Security-Policy", content: CONTENT_SECURITY_POLICY },
        },
        { tagName: "meta", attributes: { name: "referrer", content: "no-referrer" } },
      ]
    : [],

  // Monoid analytics, production builds only, so local previews are not counted.
  scripts: production
    ? [
        {
          src: `${ANALYTICS_ORIGIN}/tracker.min.js`,
          async: true,
          defer: true,
          "data-site-id": "4rkpfa49f8",
          "data-autotrack": "true",
        },
      ]
    : [],

  presets: [
    [
      "classic",
      {
        docs: {
          sidebarPath: "./sidebars.ts",
          editUrl: `${repository}/edit/main/website/`,
          showLastUpdateTime: false,
        },
        blog: false,
        theme: { customCss: "./src/css/custom.css" },
        sitemap: { changefreq: "weekly" },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    colorMode: { respectPrefersColorScheme: true },
    navbar: {
      title: "testor",
      logo: { alt: "testor", src: "img/logo.svg" },
      items: [
        { type: "docSidebar", sidebarId: "docs", position: "left", label: "Docs" },
        { to: "/docs/getting-started/quick-start", label: "Quick start", position: "left" },
        { to: "/docs/scenarios", label: "Scenarios", position: "left" },
        { to: "/docs/reference/api", label: "API", position: "left" },
        { to: "/docs/project/roadmap", label: "Roadmap", position: "right" },
        { to: "/docs/project/changelog", label: "Changelog", position: "right" },
        { href: repository, label: "GitHub", position: "right" },
      ],
    },
    footer: {
      style: "dark",
      links: [
        {
          title: "Learn",
          items: [
            { label: "Introduction", to: "/docs" },
            { label: "Quick start", to: "/docs/getting-started/quick-start" },
            { label: "How it works", to: "/docs/getting-started/how-it-works" },
            { label: "Caveats and limits", to: "/docs/caveats" },
          ],
        },
        {
          title: "Integrate",
          items: [
            { label: "HTTP API", to: "/docs/reference/api" },
            { label: "MCP server", to: "/docs/reference/mcp" },
            { label: "Security", to: "/docs/reference/security" },
            { label: "Configuration", to: "/docs/operations/configuration" },
          ],
        },
        {
          title: "Project",
          items: [
            { label: "GitHub", href: repository },
            { label: "Versioning", to: "/docs/project/versioning" },
            { label: "Roadmap", to: "/docs/project/roadmap" },
            { label: "Contributing", to: "/docs/project/contributing" },
          ],
        },
      ],
      copyright:
        "testor is MIT licensed, free for everyone, with no paid tier and no telemetry. This site uses Monoid analytics to count page views.",
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ["bash", "json", "yaml", "powershell", "elixir"],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
