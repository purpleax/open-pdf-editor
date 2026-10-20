// Builds the user guide PDF from its HTML with MuPDF's own HTML engine:
//   mutool run scripts/make-guide.js docs/guide/guide.html build/guide/Guide.pdf <version>
// Pages are Letter size; the HTML's headings become bookmarks and its links
// (to its own headings, or to the web) become links in the PDF.
"use strict"

var source = scriptArgs[0], out = scriptArgs[1], version = scriptArgs[2] || ""
if (!source || !out) throw new Error("usage: mutool run make-guide.js guide.html Guide.pdf [version]")

var html = Document.openDocument(source)
html.layout(612, 792, 11)
var count = html.countPages()

// The pages, drawn into a new PDF.
var writer = new DocumentWriter(out, "pdf", "compress")
for (var i = 0; i < count; i++) {
	var page = html.loadPage(i)
	var device = writer.beginPage(page.getBounds())
	page.run(device, Matrix.identity)
	writer.endPage()
}
writer.close()

var pdf = Document.openDocument(out).asPDF()

// A place in the HTML as a link target in the PDF (same pages, same size).
function target(uri) {
	if (/^[a-z][a-z0-9+.-]*:/i.test(uri)) return uri
	var dest = html.resolveLinkDestination(uri)
	if (dest.page < 0 || dest.page >= count) return null
	return pdf.formatLinkURI({ chapter: 0, page: dest.page, type: "XYZ", x: 0, y: dest.y || 0, zoom: 0 })
}

// Bookmarks, in the HTML's heading order and nesting.
function addOutline(items, iterator) {
	for (var k = 0; k < items.length; k++) {
		var uri = target(items[k].uri)
		iterator.insert({ title: items[k].title, uri: uri, open: false })
		if (items[k].down) {
			iterator.prev()
			iterator.down()
			addOutline(items[k].down, iterator)
			iterator.up()
			iterator.next()
		}
	}
}
var outline = html.loadOutline()
if (outline) addOutline(outline, pdf.outlineIterator())

// Links on each page.
var links = 0
for (var p = 0; p < count; p++) {
	var found = html.loadPage(p).getLinks()
	if (!found.length) continue
	var page = pdf.loadPage(p)
	for (var j = 0; j < found.length; j++) {
		var uri = target(found[j].getURI())
		if (uri) {
			page.createLink(found[j].getBounds(), uri)
			links++
		}
	}
}

pdf.setMetaData("info:Title", "Open PDF Editor Guide" + (version ? " (" + version + ")" : ""))
pdf.setMetaData("info:Author", "Open PDF Editor")
pdf.setMetaData("info:Subject", "How to use Open PDF Editor")
pdf.save(out, "compress,garbage")
print("guide: " + count + " pages, " + links + " links, written to " + out)
