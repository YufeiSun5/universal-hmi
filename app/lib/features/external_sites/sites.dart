class ExternalSite {
  const ExternalSite(this.id, this.name, this.page, this.url);
  final String id, name, url;
  final int page;
}

const externalSites = [
  ExternalSite('qiwei', '七维科技', 14, 'http://www.winxiot.com:8092/login'),
  ExternalSite('boer', '沈阳波尔', 15, 'https://www.360tp.net/'),
];

ExternalSite? externalSiteForPage(int page) {
  for (final site in externalSites) {
    if (site.page == page) return site;
  }
  return null;
}
