#!/usr/bin/env node
// Zero-dependency generation of crawlable, localized static pages.
import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = path.join(root, 'website');
const output = path.join(root, '.build/website');
const locales = [
    { file: 'en.json', route: '', enCurrent: 'aria-current="page"', zhCurrent: '' },
    { file: 'zh-CN.json', route: 'zh', enCurrent: '', zhCurrent: 'aria-current="page"' },
];
const template = await readFile(path.join(source, 'template.html'), 'utf8');
const legalTemplate = await readFile(path.join(source, 'legal.html'), 'utf8');
const escapeHTML = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
const releases = JSON.parse(await readFile(path.join(source, 'release.json'), 'utf8'));
const architectures = { arm64: 'Apple Silicon (arm64)', x86_64: 'Intel (x86_64)' };
const releaseAssets = {};
for (const architecture of Object.keys(architectures)) {
    const release = releases[architecture];
    if (!/^\d+\.\d+\.\d+$/.test(release?.version) || release.architecture !== architecture) {
        throw new Error(`Invalid website release version or architecture: ${architecture}`);
    }
    const imageName = `SI-${release.version}-${architecture}.dmg`;
    const assets = {};
    for (const [key, name] of Object.entries({ download: imageName, checksum: `${imageName}.sha256`, source: `SI-${release.version}-source.tar.gz` })) {
        const asset = release.assets?.[name];
        const url = new URL(asset?.url);
        if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash
            || !url.pathname.endsWith(`/releases/${release.version}/mac/${architecture}/${name}`)
            || !Number.isSafeInteger(asset.size) || asset.size <= 0 || !/^[a-f0-9]{64}$/.test(asset.sha256)) {
            throw new Error(`Invalid website release asset: ${architecture}/${name}`);
        }
        assets[key] = asset;
    }
    releaseAssets[architecture] = assets;
}
const dictionaries = await Promise.all(locales.map(async locale => JSON.parse(await readFile(path.join(source, 'locales', locale.file), 'utf8'))));
const keys = Object.keys(dictionaries[0]).sort().join(',');
for (const [index, dictionary] of dictionaries.entries()) {
    if (Object.keys(dictionary).sort().join(',') !== keys) throw new Error(`Translation keys differ: ${locales[index].file}`);
    for (const [key, value] of Object.entries(dictionary)) {
        if (typeof value !== 'string' || !value.trim()) throw new Error(`Missing translation: ${locales[index].file}:${key}`);
    }
}
const policies = await Promise.all(locales.map(async locale => JSON.parse(await readFile(path.join(source, 'locales', `legal.${locale.file}`), 'utf8'))));
const requireText = value => {
    if (typeof value !== 'string' || !value.trim()) throw new Error('Missing policy translation');
};
for (const [index, policy] of policies.entries()) {
    requireText(policy.updated);
    for (const kind of ['privacy', 'terms']) {
        const page = policy[kind];
        for (const field of ['title', 'description', 'intro']) requireText(page?.[field]);
        if (!Array.isArray(page.sections) || !page.sections.length) throw new Error(`Missing ${kind} sections`);
        const ids = page.sections.map(section => section.id);
        if (new Set(ids).size !== ids.length || ids.some(id => !/^[a-z][a-z-]*$/.test(id))) throw new Error(`Invalid ${kind} section IDs`);
        if (ids.join(',') !== policies[0][kind].sections.map(section => section.id).join(',')) throw new Error(`Policy sections differ: ${locales[index].file}`);
        for (const section of page.sections) {
            requireText(section.title);
            if (!Array.isArray(section.paragraphs) || !section.paragraphs.length || !Array.isArray(section.links)) throw new Error('Invalid policy section');
            section.paragraphs.forEach(requireText);
            for (const link of section.links) {
                requireText(link.label);
                const url = new URL(link.href);
                if (url.protocol !== 'https:' || url.username || url.password) throw new Error('Invalid policy link');
            }
        }
    }
}
const routeURL = (from, to) => {
    const relative = path.posix.relative(from, to) || '.';
    return `${relative.startsWith('.') ? relative : `./${relative}`}/`;
};
const render = (sourceTemplate, raw, values) => sourceTemplate.replace(/\{\{(\w+)\}\}/g, (_, key) => {
    if (Object.hasOwn(raw, key)) return raw[key];
    if (!Object.hasOwn(values, key)) throw new Error(`Unknown template key: ${key}`);
    return escapeHTML(values[key]);
});
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(path.join(source, 'assets'), path.join(output, 'assets'), { recursive: true });
for (const [index, locale] of locales.entries()) {
    const dictionary = dictionaries[index];
    const values = { ...dictionary };
    for (const [architecture, label] of Object.entries(architectures)) {
        const assets = releaseAssets[architecture];
        const size = new Intl.NumberFormat(dictionary.lang, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(assets.download.size / 1_000_000);
        values[`${architecture}DownloadUrl`] = assets.download.url;
        values[`${architecture}ChecksumUrl`] = assets.checksum.url;
        values[`${architecture}SourceUrl`] = assets.source.url;
        values[`${architecture}ReleaseDetails`] = `v${releases[architecture].version} · ${label} · ${size} MB · DMG`;
    }
    for (const kind of ['', 'privacy', 'terms']) {
        const route = path.posix.join(locale.route, kind);
        const raw = {
            base: routeURL(route, ''), home: routeURL(route, locale.route),
            enUrl: routeURL(route, kind), zhUrl: routeURL(route, path.posix.join('zh', kind)),
            privacyUrl: routeURL(route, path.posix.join(locale.route, 'privacy')),
            termsUrl: routeURL(route, path.posix.join(locale.route, 'terms')),
            enCurrent: locale.enCurrent, zhCurrent: locale.zhCurrent,
            privacyCurrent: kind === 'privacy' ? 'aria-current="page"' : '',
            termsCurrent: kind === 'terms' ? 'aria-current="page"' : '',
        };
        const pageValues = { ...values };
        if (kind) {
            const policy = policies[index][kind];
            Object.assign(pageValues, {
                title: `${policy.title} — SI`, description: policy.description,
                policyTitle: policy.title, policyIntro: policy.intro, policyUpdated: policies[index].updated,
            });
            raw.policyToc = policy.sections.map(section => `<a href="#${section.id}">${escapeHTML(section.title)}</a>`).join('');
            raw.policySections = policy.sections.map(section => `<section id="${section.id}"><h2>${escapeHTML(section.title)}</h2>${section.paragraphs.map(paragraph => `<p>${escapeHTML(paragraph)}</p>`).join('')}${section.links.map(link => `<a class="legal-reference" href="${escapeHTML(link.href)}">${escapeHTML(link.label)} ↗</a>`).join('')}</section>`).join('\n');
        }
        const destination = path.join(output, route);
        await mkdir(destination, { recursive: true });
        await writeFile(path.join(destination, 'index.html'), render(kind ? legalTemplate : template, raw, pageValues));
    }
}
await writeFile(path.join(output, '.nojekyll'), '');
console.log(`Built English and Simplified Chinese home, Privacy, and Terms pages in ${output}`);
