// Builds the test corpus with MuPDF's own PDF writer:
//   mutool run Tests/Corpus/make-corpus.js <output directory>
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

// --- signed.pdf: a (fake) signed signature field ----------------------------
// Enough structure for the app to treat it as signed: a /Sig field with a
// value. The signature itself isn't real (this MuPDF build can't sign).
function makeSigned() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [[72, 90, 24, "Signed document"]])
	var sig = doc.newDictionary()
	sig.put("Type", doc.newName("Sig"))
	sig.put("Filter", doc.newName("Adobe.PPKLite"))
	sig.put("SubFilter", doc.newName("adbe.pkcs7.detached"))
	sig.put("Contents", doc.newByteString("0000"))
	var widget = doc.newDictionary()
	widget.put("Type", doc.newName("Annot"))
	widget.put("Subtype", doc.newName("Widget"))
	widget.put("FT", doc.newName("Sig"))
	widget.put("T", doc.newString("Signature1"))
	var rect = doc.newArray(); rect.push(0); rect.push(0); rect.push(0); rect.push(0)
	widget.put("Rect", rect)
	widget.put("V", doc.addObject(sig))
	var w = doc.addObject(widget)
	var page = doc.findPage(0)
	widget.put("P", page)
	var annots = doc.newArray(); annots.push(w)
	page.put("Annots", annots)
	var fields = doc.newArray(); fields.push(w)
	var form = doc.newDictionary()
	form.put("Fields", fields)
	form.put("SigFlags", 3)
	doc.getTrailer().get("Root").put("AcroForm", form)
	doc.save(out + "/signed.pdf", "compress")
}

// --- forms.pdf: one of each kind of form field ------------------------------
// Checkboxes and radio buttons carry appearances for their states; text
// fields rely on /NeedAppearances. "total" has a calculate script that
// would fill it in if form JavaScript ran (it must not), and the form has
// XFA data, which filling in a field removes.
function formDocument() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [[72, 60, 24, "Form"]])
	var helv = doc.addObject({ Type: doc.newName("Font"), Subtype: doc.newName("Type1"),
		BaseFont: doc.newName("Helvetica"), Encoding: doc.newName("WinAnsiEncoding") })
	var form = doc.newDictionary()
	form.put("Fields", doc.newArray())
	form.put("DA", doc.newString("/Helv 0 Tf 0 g"))
	form.put("DR", { Font: { Helv: helv } })
	form.put("NeedAppearances", true)
	doc.getTrailer().get("Root").put("AcroForm", form)
	return doc
}

function stateAppearances(doc, size, onState) {
	function look(content) {
		return doc.addStream(content, { Type: doc.newName("XObject"), Subtype: doc.newName("Form"), BBox: [0, 0, size, size] })
	}
	var n = doc.newDictionary()
	n.put(onState, look("0 0 1 rg 3 3 " + (size - 6) + " " + (size - 6) + " re f"))
	n.put("Off", look("0 g 0.5 w 0.5 0.5 " + (size - 1) + " " + (size - 1) + " re S"))
	var ap = doc.newDictionary()
	ap.put("N", n)
	return ap
}

// A widget on page 0, in /Annots; also in /AcroForm/Fields unless it has a parent.
function addField(doc, fields, rect) {
	var widget = doc.newDictionary()
	widget.put("Type", doc.newName("Annot"))
	widget.put("Subtype", doc.newName("Widget"))
	widget.put("Rect", rect)
	widget.put("F", 4)
	for (var k in fields) widget.put(k, fields[k])
	var w = doc.addObject(widget)
	var page = doc.findPage(0)
	w.put("P", page)
	var annots = page.get("Annots")
	if (!annots || annots.isNull()) { annots = doc.newArray(); page.put("Annots", annots) }
	annots.push(w)
	if (!fields.Parent) doc.getTrailer().get("Root").get("AcroForm").get("Fields").push(w)
	return w
}

function makeForms() {
	var doc = formDocument()
	var Tx = doc.newName("Tx"), Btn = doc.newName("Btn"), Ch = doc.newName("Ch")
	var da = doc.newString("/Helv 12 Tf 0 g")
	addField(doc, { FT: Tx, T: doc.newString("name"), V: doc.newString("Ada"), DA: da, TU: doc.newString("Your name") }, [72, 700, 300, 720])
	addField(doc, { FT: Tx, T: doc.newString("notes"), Ff: 1 << 12, DA: da }, [72, 620, 300, 690])
	addField(doc, { FT: Tx, T: doc.newString("zip"), MaxLen: 5, DA: da }, [72, 590, 150, 610])
	addField(doc, { FT: Tx, T: doc.newString("pin"), Ff: 1 << 13, DA: da }, [200, 590, 300, 610])
	addField(doc, { FT: Tx, T: doc.newString("code"), Ff: 1 << 24, MaxLen: 6, DA: da }, [320, 590, 440, 610])
	addField(doc, { FT: Btn, T: doc.newString("agree"), V: doc.newName("Off"), AS: doc.newName("Off"),
		AP: stateAppearances(doc, 14, "Yes") }, [72, 550, 86, 564])

	// A radio group: a parent field with three buttons, none off once chosen.
	var group = doc.addObject({ FT: Btn, T: doc.newString("size"), Ff: (1 << 15) | (1 << 14), V: doc.newName("Off"), Kids: [] })
	doc.getTrailer().get("Root").get("AcroForm").get("Fields").push(group)
	var states = ["S", "M", "L"]
	for (var i = 0; i < 3; i++) {
		var kid = addField(doc, { Parent: group, AS: doc.newName("Off"), AP: stateAppearances(doc, 14, states[i]) },
			[72 + i * 40, 510, 86 + i * 40, 524])
		group.get("Kids").push(kid)
	}

	addField(doc, { FT: Ch, T: doc.newString("colour"), Ff: 1 << 17, V: doc.newString("g"), DA: da,
		Opt: [[doc.newString("r"), doc.newString("Red")], [doc.newString("g"), doc.newString("Green")], [doc.newString("b"), doc.newString("Blue")]] }, [72, 460, 200, 480])
	addField(doc, { FT: Ch, T: doc.newString("fruits"), Ff: 1 << 21, DA: da,
		Opt: [doc.newString("Apple"), doc.newString("Banana"), doc.newString("Cherry")] }, [72, 380, 200, 440])
	addField(doc, { FT: Tx, T: doc.newString("locked"), Ff: 1, V: doc.newString("Fixed"), DA: da }, [72, 340, 300, 360])
	addField(doc, { FT: doc.newName("Sig"), T: doc.newString("signature") }, [72, 260, 300, 320])
	var calculate = doc.addObject({ S: doc.newName("JavaScript"), JS: doc.newString("event.value = 'calculated';") })
	var total = addField(doc, { FT: Tx, T: doc.newString("total"), DA: da, AA: { C: calculate } }, [320, 700, 440, 720])
	var form = doc.getTrailer().get("Root").get("AcroForm")
	form.put("CO", [total])
	form.put("XFA", doc.addStream("<xdp:xdp xmlns:xdp=\"http://ns.adobe.com/xdp/\"/>", {}))
	doc.save(out + "/forms.pdf", "compress")
}

// --- formbomb.pdf: more fields and choices than the limits, a name over
// MuPDF's 16 KB, and fields that are their own parents.
function makeFormBomb() {
	var doc = formDocument()
	var Tx = doc.newName("Tx")
	for (var i = 0; i < 2500; i++)
		addField(doc, { FT: Tx, T: doc.newString("f" + i) }, [10 + (i % 50) * 11, 10 + Math.floor(i / 50) * 11, 20 + (i % 50) * 11, 20 + Math.floor(i / 50) * 11])
	doc.save(out + "/formbomb.pdf", "compress")

	doc = formDocument()
	var options = []
	for (var j = 0; j < 5000; j++) options.push(doc.newString("Option " + j))
	addField(doc, { FT: doc.newName("Ch"), T: doc.newString("many"), Ff: 1 << 17, Opt: options }, [72, 700, 300, 720])
	var long = ""
	while (long.length < 20000) long += "long name "
	addField(doc, { FT: Tx, T: doc.newString(long) }, [72, 650, 300, 670])
	var a = addField(doc, { FT: Tx, T: doc.newString("loop") }, [72, 600, 300, 620])
	var b = doc.addObject({ T: doc.newString("back"), Kids: [a], Parent: a })
	a.put("Parent", b)
	doc.save(out + "/formloop.pdf", "compress")
}

// --- Hostile files, for the security tests ----------------------------------

// Absurd page sizes: a 1 x 10,000,000 point strip, and a page scaled by
// /UserUnit to about 1e23 points.
function makeHuge() {
	var doc = newDocument()
	addTextPage(doc, [0, 0, 1, 10000000], [])
	var p = addTextPage(doc, [0, 0, 1000, 1000], [[10, 20, 12, "User unit"]])
	var page = doc.findPage(p)
	var box = doc.newArray()
	box.push(0); box.push(0); box.push(9e18); box.push(9e18)
	page.put("MediaBox", box)
	page.put("UserUnit", 10000)
	doc.save(out + "/huge.pdf", "compress")
}

// An outline nested 5,000 levels deep.
function makeDeepOutline() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [[72, 90, 24, "Deep outline"]])
	var outlines = doc.addObject(doc.newDictionary())
	outlines.put("Type", doc.newName("Outlines"))
	var parent = outlines
	for (var i = 0; i < 5000; i++) {
		var item = doc.addObject(doc.newDictionary())
		item.put("Title", doc.newString("Level " + (i + 1)))
		item.put("Parent", parent)
		parent.put("First", item)
		parent.put("Last", item)
		parent = item
	}
	doc.getTrailer().get("Root").put("Outlines", outlines)
	doc.save(out + "/deep-outline.pdf", "compress")
}

// Three pages with a classic xref table, which make-corpus.sh then damages:
// one entry for page 3 points to the wrong place (lazy.pdf).
function makeLazySource() {
	var doc = newDocument()
	for (var i = 1; i <= 3; i++) addTextPage(doc, LETTER, [[72, 90, 24, "Lazy page " + i]])
	doc.save(out + "/lazy-source.pdf", "")
}

// The text document with an xref stream, as most modern PDFs have.
function makeXrefStream() {
	var doc = new PDFDocument(out + "/text.pdf")
	doc.save(out + "/xrefstream.pdf", "compress,objstms")
}

// One 20,000-point stroke referenced 1,000 times in an /InkList.
function makeInkBomb() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [[72, 90, 24, "Ink bomb"]])
	var stroke = doc.newArray()
	for (var i = 0; i < 20000; i++) { stroke.push(100 + (i % 400)); stroke.push(100 + (i % 500)) }
	var strokeRef = doc.addObject(stroke)
	var ink = doc.newArray()
	for (var j = 0; j < 1000; j++) ink.push(strokeRef)
	var annot = doc.newDictionary()
	annot.put("Type", doc.newName("Annot"))
	annot.put("Subtype", doc.newName("Ink"))
	var rect = doc.newArray(); rect.push(100); rect.push(100); rect.push(500); rect.push(600)
	annot.put("Rect", rect)
	annot.put("InkList", ink)
	var annots = doc.newArray(); annots.push(doc.addObject(annot))
	doc.findPage(0).put("Annots", annots)
	doc.save(out + "/inkbomb.pdf", "compress")
}

// A direct (unnumbered) annotation, and one object listed twice in /Annots.
function makeDupes() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [[72, 90, 24, "Duplicates"]])
	function square(x) {
		var d = doc.newDictionary()
		d.put("Type", doc.newName("Annot"))
		d.put("Subtype", doc.newName("Square"))
		var r = doc.newArray(); r.push(x); r.push(500); r.push(x + 80); r.push(580)
		d.put("Rect", r)
		return d
	}
	var annots = doc.newArray()
	annots.push(square(72))                       // direct
	var shared = doc.addObject(square(200))
	annots.push(shared)
	annots.push(shared)                           // twice
	doc.findPage(0).put("Annots", annots)
	doc.save(out + "/dupes.pdf", "compress")
}

// A note with a chain of 3,000 replies, each replying to the last.
function makeReplyChain() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [[72, 90, 24, "Reply chain"]])
	var annots = doc.newArray()
	var previous = null
	for (var i = 0; i <= 3000; i++) {
		var d = doc.newDictionary()
		d.put("Type", doc.newName("Annot"))
		d.put("Subtype", doc.newName("Text"))
		var r = doc.newArray(); r.push(300); r.push(300); r.push(320); r.push(320)
		d.put("Rect", r)
		d.put("Contents", doc.newString(i == 0 ? "Root" : "Reply " + i))
		if (previous) d.put("IRT", previous)
		previous = doc.addObject(d)
		annots.push(previous)
	}
	doc.findPage(0).put("Annots", annots)
	doc.save(out + "/chain.pdf", "compress")
}

// An HTML file with a .pdf name: must not open in another engine.
// Text boxes with a style (/DS) and no appearance: MuPDF lays them out with
// its HTML engine and HarfBuzz when a page is drawn.
function makeFreeText() {
	var doc = newDocument()
	for (var i = 0; i < 3; i++) {
		addTextPage(doc, LETTER, [[72, 40, 14, "Free text " + (i + 1)]])
		var d = doc.newDictionary()
		d.put("Type", doc.newName("Annot"))
		d.put("Subtype", doc.newName("FreeText"))
		var r = doc.newArray(); r.push(50); r.push(50); r.push(550); r.push(700)
		d.put("Rect", r)
		d.put("Contents", "Text box " + i + " with enough words to shape and wrap across several lines of the box")
		d.put("DA", "/Helv 14 Tf 0 g")
		d.put("DS", "font-family:Helvetica;font-size:14pt;color:#000000")
		var annots = doc.newArray()
		annots.push(doc.addObject(d))
		doc.findPage(i).put("Annots", annots)
	}
	doc.save(out + "/freetext.pdf", "compress")
}

function makeNotAPDF() {
	var buffer = new Buffer()
	buffer.write("<html><body><h1>Not a PDF</h1><p>Some text.</p></body></html>\n")
	buffer.save(out + "/not-a-pdf.pdf")
}

makeText()
makeXrefStream()
makeLazySource()
makeInkBomb()
makeDupes()
makeReplyChain()
makeSigned()
makeHuge()
makeDeepOutline()
makeNotAPDF()
makeFreeText()
makeMixed()
makeAttachments()
makeLayers()
makeLong()
makeForms()
makeFormBomb()
print("corpus: wrote the test PDFs to " + out)
