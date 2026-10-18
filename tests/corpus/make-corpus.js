// Builds the test corpus with MuPDF's own PDF writer:
//   mutool run tests/corpus/make-corpus.js <output directory>
// Every file is generated, so the corpus carries no third-party content.
"use strict"

var out = scriptArgs[0]
if (!out) throw new Error("usage: mutool run make-corpus.js <output directory>")

function newDocument() {
	var doc = new PDFDocument()
	doc.font = doc.addSimpleFont(new Font("Times-Roman"), "Latin")
	return doc
}

// A PDF string for the Latin (WinAnsi) font: characters above ASCII as octal escapes.
function escapeText(s) {
	var out = ""
	for (var i = 0; i < s.length; i++) {
		var c = s.charCodeAt(i)
		if (c === 92 || c === 40 || c === 41) out += "\\" + s[i]
		else if (c < 128) out += s[i]
		else out += "\\" + c.toString(8)
	}
	return out
}

// A page with lines of text: lines is a list of [x, y-from-top, size, text].
function addTextPage(doc, box, lines, extraContent, extraResources) {
	var height = box[3] - box[1]
	var content = ""
	for (var i = 0; i < lines.length; i++) {
		var l = lines[i]
		content += "BT /F1 " + l[2] + " Tf " + (box[0] + l[0]) + " " + (box[1] + height - l[1]) + " Td (" + escapeText(l[3]) + ") Tj ET\n"
	}
	content += extraContent || ""
	var resources = { Font: { F1: doc.font } }
	if (extraResources) for (var k in extraResources) resources[k] = extraResources[k]
	var page = doc.addPage(box, 0, resources, content)
	doc.insertPage(-1, page)
	return doc.countPages() - 1
}

var LETTER = [0, 0, 612, 792]

// --- text.pdf: three pages of known text, an outline and links -------------
function makeText() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [
		[72, 90, 28, "Chapter One"],
		[72, 140, 14, "The quick brown fox jumps over the lazy dog."],
		[72, 160, 14, "Search should find this phrase at the end of"],
		[72, 180, 14, "the line, and a Café résumé with accents."],
		[72, 220, 14, "Go to page three"],
		[72, 240, 14, "Visit example.com"],
	])
	addTextPage(doc, LETTER, [
		[72, 90, 28, "Chapter Two"],
		[72, 140, 14, "Page two mentions the fox once more."],
		[72, 160, 14, "Foxes are not dogs; FOX in capitals still matches."],
	])
	addTextPage(doc, LETTER, [
		[72, 90, 28, "Chapter Three"],
		[72, 140, 14, "This is the target of the link on page one."],
		[72, 600, 14, "A paragraph near the bottom of page three."],
	])

	var first = doc.loadPage(0)
	// Link rectangles are in MuPDF's page space: y measured down from the top.
	first.createLink([70, 205, 180, 224], "#page=3")
	first.createLink([70, 225, 180, 244], "https://example.com/")

	var it = doc.outlineIterator()
	it.insert({ title: "Chapter One", uri: "#page=1", open: true })
	it.insert({ title: "Chapter Two", uri: "#page=2", open: true })
	it.insert({ title: "Chapter Three", uri: "#page=3", open: false })
	// A child under Chapter Two.
	it = doc.outlineIterator()
	it.next()
	it.down()
	it.insert({ title: "Foxes and dogs", uri: "#page=2&zoom=0,72,620", open: false })
	// Chapter Two was childless when it was marked open; mark it again now.
	it.up()
	it.update({ title: "Chapter Two", uri: "#page=2", open: true })

	doc.save(out + "/text.pdf", "compress,garbage")
	// The same document locked with a password.
	doc.save(out + "/encrypted.pdf", "compress,garbage,encrypt=aes-256,user-password=secret,owner-password=owner")
}

// --- mixed.pdf: page sizes, rotation and box origins ------------------------
function makeMixed() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [[72, 90, 24, "Letter portrait"]])
	addTextPage(doc, [0, 0, 842, 595], [[72, 90, 24, "A4 landscape"]])
	var rotated = addTextPage(doc, LETTER, [[72, 90, 24, "Letter with Rotate 90"]])
	doc.findPage(rotated).put("Rotate", 90)
	addTextPage(doc, [0, 0, 200, 200], [[20, 40, 14, "Small square"]])
	addTextPage(doc, [100, 100, 400, 500], [[20, 40, 14, "Offset media box"]],
		"0 0.5 0 rg 100 100 20 20 re f\n")
	doc.save(out + "/mixed.pdf", "compress,garbage")
}

// --- attachments.pdf: an embedded file ---------------------------------------
function makeAttachments() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [[72, 90, 24, "This document has an attachment."]])
	var contents = new Buffer()
	contents.write("hello attachment\n")
	var fs = doc.addEmbeddedFile("notes.txt", "text/plain", contents, -1, -1, false)
	var root = doc.getTrailer().get("Root")
	var names = doc.newDictionary()
	var files = doc.newDictionary()
	var list = doc.newArray()
	list.push(doc.newString("notes.txt"))
	list.push(fs)
	files.put("Names", list)
	names.put("EmbeddedFiles", files)
	root.put("Names", names)
	doc.save(out + "/attachments.pdf", "compress,garbage")
}

// --- layers.pdf: two optional content groups, one off -----------------------
function makeLayers() {
	var doc = newDocument()
	function ocg(name) {
		var d = doc.newDictionary()
		d.put("Type", doc.newName("OCG"))
		d.put("Name", doc.newString(name))
		return doc.addObject(d)
	}
	var red = ocg("Red square")
	var blue = ocg("Blue square")
	var properties = doc.newDictionary()
	properties.put("OC1", red)
	properties.put("OC2", blue)
	addTextPage(doc, LETTER, [[72, 90, 24, "Layers"]],
		"/OC /OC1 BDC 1 0 0 rg 72 500 200 100 re f EMC\n/OC /OC2 BDC 0 0 1 rg 320 500 200 100 re f EMC\n",
		{ Properties: properties })
	var ocgs = doc.newArray(); ocgs.push(red); ocgs.push(blue)
	var order = doc.newArray(); order.push(red); order.push(blue)
	var on = doc.newArray(); on.push(red)
	var off = doc.newArray(); off.push(blue)
	var d = doc.newDictionary()
	d.put("Order", order)
	d.put("ON", on)
	d.put("OFF", off)
	var oc = doc.newDictionary()
	oc.put("OCGs", ocgs)
	oc.put("D", d)
	doc.getTrailer().get("Root").put("OCProperties", oc)
	doc.save(out + "/layers.pdf", "compress,garbage")
}

// --- long.pdf: many pages, for scrolling and search -------------------------
function makeLong() {
	var doc = newDocument()
	for (var i = 1; i <= 300; i++) {
		var lines = [[72, 90, 24, "Page " + i]]
		for (var j = 0; j < 30; j++)
			lines.push([72, 130 + j * 20, 11, "Line " + (j + 1) + " of page " + i + ": lorem ipsum dolor sit amet, consectetur adipiscing elit."])
		if (i === 250) lines.push([72, 760, 11, "needle in a haystack"])
		addTextPage(doc, LETTER, lines)
	}
	doc.save(out + "/long.pdf", "compress,garbage")
}

makeText()
makeMixed()
makeAttachments()
makeLayers()
makeLong()
print("corpus: wrote text, encrypted, mixed, attachments, layers and long PDFs to " + out)
