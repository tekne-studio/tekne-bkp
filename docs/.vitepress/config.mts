import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitepress';

const docs = fileURLToPath(new URL('..', import.meta.url));
const repo = 'https://github.com/tekne-studio/tekne-bkp';

type Page = { link: string; title: string; group: string; order: number };

// Each page names its title, group and order in frontmatter: the sidebar is built from them.
function pages(folder: string): Page[] {
	return readdirSync(`${docs}${folder}`)
		.filter((f) => f.endsWith('.md') && f !== 'index.md')
		.map((f) => {
			const front = readFileSync(`${docs}${folder}${f}`, 'utf8').split('\n---')[0];
			const field = (name: string) => front.match(new RegExp(`^${name}:\\s*(.+)$`, 'm'))?.[1].trim() ?? '';
			return { link: `/${folder}${f.replace(/\.md$/, '')}`, title: field('title'), group: field('group'), order: Number(field('order') || 99) };
		});
}

const sidebar = (folder: string, groups: string[]) =>
	groups.map((group) => ({
		text: group,
		items: pages(folder)
			.filter((p) => p.group === group)
			.sort((a, b) => a.order - b.order || a.title.localeCompare(b.title))
			.map((p) => ({ text: p.title, link: p.link }))
	}));

export default defineConfig({
	title: 'tekne-bkp',
	description: 'Backup, staging clone and owner zip for WordPress, Moodle and Craft sites, over restic',
	lang: 'en',
	// GitHub Pages serves the site under the repository's name
	base: '/tekne-bkp/',
	cleanUrls: true,
	lastUpdated: true,
	themeConfig: {
		nav: [
			{ text: 'Manual', link: '/manual/', activeMatch: '^/manual/' },
			{ text: 'Docs', link: '/backup', activeMatch: '^/(?!manual/)' }
		],
		sidebar: {
			'/manual/': sidebar('manual/', ['Setup', 'Day to day', 'Trouble']),
			'/': sidebar('', ['Guides', 'Reference'])
		},
		search: { provider: 'local' },
		socialLinks: [{ icon: 'github', link: repo }],
		editLink: { pattern: `${repo}/edit/master/docs/:path` }
	}
});
