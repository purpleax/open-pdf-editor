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

// --- redact.pdf: leftovers redaction must reach: a field shown by two
// widgets, a note the structure tree also refers to, and XFA data.
function makeRedactLeftovers() {
	var doc = formDocument()
	var da = doc.newString("/Helv 12 Tf 0 g")
	var secret = doc.addObject({ FT: doc.newName("Tx"), T: doc.newString("secret"), V: doc.newString("secret-sibling"), DA: da, Kids: [] })
	doc.getTrailer().get("Root").get("AcroForm").get("Fields").push(secret)
	secret.get("Kids").push(addField(doc, { Parent: secret }, [72, 700, 300, 720]))
	var shown = doc.addStream("/Tx BMC BT /Helv 12 Tf 2 5 Td (secret-sibling) Tj ET EMC",
		{ Type: doc.newName("XObject"), Subtype: doc.newName("Form"), BBox: [0, 0, 228, 20],
		  Resources: doc.getTrailer().get("Root").get("AcroForm").get("DR") })
	secret.get("Kids").push(addField(doc, { Parent: secret, AP: { N: shown } }, [72, 600, 300, 620]))
	var page = doc.findPage(0)
	var note = doc.addObject({ Type: doc.newName("Annot"), Subtype: doc.newName("Text"), Rect: [400, 700, 420, 720],
		Contents: doc.newString("secret-in-struct"), P: page })
	page.get("Annots").push(note)
	var link = doc.addObject({ Type: doc.newName("Annot"), Subtype: doc.newName("Link"), Rect: [400, 600, 500, 620],
		A: { S: doc.newName("URI"), URI: doc.newString("https://secret-link.example/") }, P: page })
	page.get("Annots").push(link)
	doc.getTrailer().get("Root").put("StructTreeRoot", { Type: doc.newName("StructTreeRoot"),
		K: [{ Type: doc.newName("OBJR"), Obj: note, Pg: page }, { Type: doc.newName("OBJR"), Obj: link, Pg: page }] })
	doc.getTrailer().get("Root").get("AcroForm").put("XFA",
		doc.addStream("<xdp:xdp xmlns:xdp=\"http://ns.adobe.com/xdp/\"><xfa:datasets><secret>xfa-secret</secret></xfa:datasets></xdp:xdp>", {}))
	doc.save(out + "/redact.pdf", "")
}

// --- paragraphs.pdf: text as paragraphs, for paragraph editing --------------
// Page 1: a centred heading, a right-aligned line, a 3-line paragraph with a
// superscript, and a justified 4-line paragraph sharing one BT with the
// 2-line paragraph after it. Page 2: two columns on shared baselines, a
// bullet with a hanging indent, fake bold, a CID-font paragraph and an
// underline drawn as a rule. Page 3: text that can't be edited. Page 4 is
// rotated, page 5 cropped.
function makeParagraphs() {
	var doc = newDocument()
	var times = new Font("Times-Roman")
	function width(text, size) {
		var w = 0
		for (var i = 0; i < text.length; i++) w += times.advanceGlyph(times.encodeCharacter(text.charCodeAt(i)), 0)
		return w * size
	}
	function line(x, y, size, text) {
		return "BT /F1 " + size + " Tf " + x + " " + y + " Td (" + escapeText(text) + ") Tj ET\n"
	}
	var top = 792
	var c = ""
	var heading = "A Heading in the Middle"
	c += line((612 - width(heading, 18)) / 2, top - 60, 18, heading)
	var right = "Set against the right margin"
	c += line(540 - width(right, 12), top - 84, 12, right)
	var first = ["The first paragraph has three lines, each drawn with", "its own text object, as many programs write them, and", "it ends here on the third line."]
	for (var i = 0; i < 3; i++) c += line(72, top - 120 - i * 14.4, 12, first[i])
	c += "BT /F1 7 Tf " + (72 + width(first[0], 12) + 1) + " " + (top - 120 + 5) + " Td (2) Tj ET\n"
	// Justified: each line but the last spread with Tw to a few points past
	// the widest.
	var just = ["Justified text fills the whole width of the column by", "spreading out the spaces between its words, so that",
		"both edges line up neatly down the page from top to", "the bottom."]
	var measure = 0
	for (var i = 0; i < just.length - 1; i++) measure = Math.max(measure, width(just[i], 12))
	measure += 6
	var shared = ["A paragraph after it, in the same text", "object as the justified one above."]
	c += "BT /F1 12 Tf 14.4 TL 72 " + (top - 190) + " Td\n"
	for (var i = 0; i < just.length; i++) {
		var spaces = just[i].split(" ").length - 1
		var tw = i < just.length - 1 && spaces ? (measure - width(just[i], 12)) / spaces : 0
		c += tw.toFixed(3) + " Tw (" + escapeText(just[i]) + ") Tj T*\n"
	}
	c += "0 Tw 0 -14.4 Td (" + escapeText(shared[0]) + ") Tj T* (" + escapeText(shared[1]) + ") Tj ET\n"
	var page = doc.addPage(LETTER, 0, { Font: { F1: doc.font } }, c)
	doc.insertPage(-1, page)

	// Page 2.
	var cid = doc.addFont(new Font("Helvetica"))
	var helv = new Font("Helvetica")
	function hex(text) {
		var out = "<"
		for (var i = 0; i < text.length; i++) out += ("0000" + helv.encodeCharacter(text.charCodeAt(i)).toString(16)).slice(-4)
		return out + ">"
	}
	c = ""
	var left = ["The left column has", "three short lines of", "its own text here."]
	var rightCol = ["The right column sits", "on the same baselines", "as the left one does."]
	for (var i = 0; i < 3; i++) {
		c += line(72, top - 80 - i * 14.4, 12, left[i])
		c += line(320, top - 80 - i * 14.4, 12, rightCol[i])
	}
	c += line(72, top - 160, 12, String.fromCharCode(149))   // a bullet in WinAnsi
	c += line(90, top - 160, 12, "A bulleted item whose text wraps")
	c += line(90, top - 174.4, 12, "onto a second, indented line.")
	c += line(72, top - 220, 12, "Fake bold drawn twice")
	c += line(72.2, top - 220, 12, "Fake bold drawn twice")
	c += "BT /F2 12 Tf 72 " + (top - 260) + " Td " + hex("Wide text in a CID font,") + " Tj 0 -14.4 Td " + hex("over two lines.") + " Tj ET\n"
	c += line(72, top - 360, 12, "Ada Lovelace")
	c += line(72, top - 374.4, 12, "12 St James's Square")
	c += line(72, top - 388.8, 12, "London, the long way round")
	c += line(72, top - 310, 12, "An underlined line")
	c += "0.5 w 72 " + (top - 312) + " m " + (72 + width("An underlined line", 12)) + " " + (top - 312) + " l S\n"
	page = doc.addPage(LETTER, 0, { Font: { F1: doc.font, F2: cid } }, c)
	doc.insertPage(-1, page)

	// Page 3: text that can't be edited.
	var form = doc.addStream("BT /F1 12 Tf 0 0 Td (Text inside a form) Tj ET",
		{ Type: doc.newName("XObject"), Subtype: doc.newName("Form"), BBox: [0, 0, 300, 50], Resources: { Font: { F1: doc.font } } })
	var charproc = doc.addStream("500 0 0 0 400 400 d1 0 0 400 400 re f", {})
	var type3 = doc.addObject({ Type: doc.newName("Font"), Subtype: doc.newName("Type3"),
		FontBBox: [0, 0, 400, 400], FontMatrix: [0.001, 0, 0, 0.001, 0, 0],
		CharProcs: { a: charproc }, Encoding: { Type: doc.newName("Encoding"), Differences: [97, doc.newName("a")] },
		FirstChar: 97, LastChar: 97, Widths: [500], Resources: {} })
	c = "q 1 0 0 1 72 " + (top - 80) + " cm /Fm0 Do Q\n"
	c += "BT /F3 12 Tf 72 " + (top - 140) + " Td (aaa) Tj ET\n"
	c += "BT /F1 12 Tf 3 Tr 72 " + (top - 180) + " Td (Invisible text) Tj ET\n"
	c += "q BT /F1 12 Tf 7 Tr 72 " + (top - 220) + " Td (Clipping text) Tj ET Q\n"
	c += "BT /F1 12 Tf 0.866 0.5 -0.5 0.866 72 " + (top - 300) + " Tm (Turned text) Tj ET\n"
	page = doc.addPage(LETTER, 0, { Font: { F1: doc.font, F3: type3 }, XObject: { Fm0: form } }, c)
	doc.insertPage(-1, page)

	// Pages 4 and 5: rotated, and cropped.
	// Drawn turned back a quarter, so it reads upright on the turned page.
	c = "BT /F1 12 Tf 0 1 -1 0 100 72 Tm (" + escapeText("On a page turned a quarter,") + ") Tj 0 -14.4 Td ("
		+ escapeText("this paragraph has two lines.") + ") Tj ET\n"
	page = doc.addPage(LETTER, 90, { Font: { F1: doc.font } }, c)
	doc.insertPage(-1, page)
	c = line(172, top - 200, 12, "On a cropped page, this") + line(172, top - 214.4, 12, "paragraph has two lines.")
	page = doc.addPage(LETTER, 0, { Font: { F1: doc.font } }, c)
	doc.insertPage(-1, page)
	doc.findPage(4).put("CropBox", [100, 100, 500, 700])
	doc.save(out + "/paragraphs.pdf", "compress")
}

// --- parabomb.pdf: pages that would make paragraph editing slow or wrong:
// a 120,000-character line in a 1-point font, 30,000 glyphs drawn on one
// spot, fonts with long names (40 and 130 characters), and a glyph placed
// absurdly far off the page.
function makeParaBomb() {
	var doc = newDocument()
	var long = ""
	for (var i = 0; i < 60000; i++) long += "a "
	var page = doc.addPage(LETTER, 0, { Font: { F1: doc.font } }, "BT /F1 1 Tf 0 700 Td (" + long + ") Tj ET\n")
	doc.insertPage(-1, page)
	var pile = "BT /F1 12 Tf\n"
	for (var i = 0; i < 30000; i++) pile += "1 0 0 1 72 700 Tm (" + String.fromCharCode(65 + (i % 26)) + ") Tj\n"
	page = doc.addPage(LETTER, 0, { Font: { F1: doc.font } }, pile + "ET\n")
	doc.insertPage(-1, page)
	var forty = "F" + new Array(40).join("x"), huge = "F" + new Array(130).join("y")
	var fonts = {}
	fonts[forty] = doc.font
	fonts[huge] = doc.font
	page = doc.addPage(LETTER, 0, { Font: fonts },
		"BT /" + forty + " 12 Tf 72 700 Td (A long font name) Tj ET\n" +
		"BT /" + huge + " 12 Tf 72 600 Td (An even longer one) Tj ET\n" +
		"BT /" + forty + " 12 Tf 1 0 0 1 1e30 1e30 Tm (Far away) Tj ET\n")
	doc.insertPage(-1, page)
	// A page full of tiny text: 150,000 characters on 650 lines.
	var text = "", row = new Array(231).join("x")
	for (var i = 0; i < 650; i++) text += "BT /F1 1 Tf 20 " + (780 - i * 1.2).toFixed(1) + " Td (" + row + ") Tj ET\n"
	page = doc.addPage(LETTER, 0, { Font: { F1: doc.font } }, text)
	doc.insertPage(-1, page)
	doc.save(out + "/parabomb.pdf", "compress")
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
	makeFormTrees()
}

// --- Field trees that MuPDF's own walks don't survive (from the 0.4.0
// security review): a radio group that is its own kid, a text field that is
// its own kid, fields reached many times over, and options that are big or
// many but cost little in the file.
function makeFormTrees() {
	var doc = formDocument()
	var Btn = doc.newName("Btn"), Tx = doc.newName("Tx")
	var group = doc.addObject({ FT: Btn, T: doc.newString("loopgroup"), Ff: 1 << 15, V: doc.newName("Off"), Kids: [] })
	doc.getTrailer().get("Root").get("AcroForm").get("Fields").push(group)
	var kid = addField(doc, { Parent: group, AS: doc.newName("Off"), AP: stateAppearances(doc, 14, "On") }, [72, 700, 86, 714])
	group.get("Kids").push(kid)
	group.get("Kids").push(group)
	var text = addField(doc, { FT: Tx, T: doc.newString("looptext") }, [72, 650, 300, 670])
	text.put("Kids", [text])
	doc.save(out + "/formcycle.pdf", "compress")

	doc = formDocument()
	var fields = doc.getTrailer().get("Root").get("AcroForm").get("Fields")
	var next = doc.addObject({ FT: Tx, T: doc.newString("leaf") })
	for (var i = 0; i < 60; i++) next = doc.addObject({ Kids: [next, next] })
	fields.push(next)
	addField(doc, { FT: Tx, T: doc.newString("plain") }, [72, 700, 300, 720])
	doc.save(out + "/formdag.pdf", "compress")

	doc = formDocument()
	var big = ""
	while (big.length < 100000) big += "0123456789"
	var shared = doc.addObject(doc.newString(big))
	var options = []
	for (var j = 0; j < 1000; j++) options.push(shared)
	addField(doc, { FT: doc.newName("Ch"), T: doc.newString("big"), Ff: 1 << 17, Opt: options }, [72, 700, 300, 720])
	var empty = []
	for (var k = 0; k < 1000; k++) empty.push(doc.newString(""))
	var many = doc.addObject(empty)
	for (var m = 0; m < 2000; m++)
		addField(doc, { FT: doc.newName("Ch"), T: doc.newString("c" + m), Opt: many }, [10 + (m % 50) * 11, 10 + Math.floor(m / 50) * 11, 20 + (m % 50) * 11, 20 + Math.floor(m / 50) * 11])
	// Without NeedAppearances: MuPDF would redraw 2,000 lists as the page
	// loads (slow, but not the listing this file tests).
	doc.getTrailer().get("Root").get("AcroForm").put("NeedAppearances", false)
	doc.save(out + "/formheavy.pdf", "compress")

	// /Parent and /Kids that disagree (from the re-review): each widget's
	// parent leads to a top field with no /Kids, but MuPDF also walks down
	// from the widget or its group, where the loop or the doubled kids are.
	doc = formDocument()
	fields = doc.getTrailer().get("Root").get("AcroForm").get("Fields")
	var topRadio = doc.addObject({ T: doc.newString("top1") })
	var looping = doc.addObject({ FT: Btn, T: doc.newString("g"), Ff: 1 << 15, V: doc.newName("Off"), Parent: topRadio, Kids: [] })
	var button = addField(doc, { Parent: looping, AS: doc.newName("Off"), AP: stateAppearances(doc, 14, "On") }, [72, 700, 86, 714])
	looping.get("Kids").push(looping)
	looping.get("Kids").push(button)
	fields.push(topRadio)
	var topText = doc.addObject({ T: doc.newString("top2") })
	var selfish = addField(doc, { FT: Tx, T: doc.newString("a"), Parent: topText }, [72, 650, 300, 670])
	selfish.put("Kids", [selfish])
	fields.push(topText)
	var topDag = doc.addObject({ T: doc.newString("top3") })
	var node = doc.addObject({ T: doc.newString("leaf") })
	for (var d = 0; d < 40; d++) node = doc.addObject({ Kids: [node, node] })
	addField(doc, { FT: Tx, T: doc.newString("b"), Parent: topDag, Kids: [node] }, [72, 600, 300, 620])
	fields.push(topDag)
	// addField put the widgets in /Fields too: only the tops belong there.
	var tops = doc.newArray()
	tops.push(topRadio); tops.push(topText); tops.push(topDag)
	doc.getTrailer().get("Root").get("AcroForm").put("Fields", tops)
	doc.save(out + "/formbypass.pdf", "compress")

	// A large form: one group of 1,001 text fields, and 15,000 more names.
	doc = formDocument()
	fields = doc.getTrailer().get("Root").get("AcroForm").get("Fields")
	var root = doc.addObject({ T: doc.newString("form1"), Kids: [] })
	fields.push(root)
	for (var g = 0; g < 1001; g++) {
		var w = addField(doc, { FT: Tx, T: doc.newString("f" + g), Parent: root }, [10 + (g % 50) * 11, 10 + Math.floor(g / 50) * 11, 20 + (g % 50) * 11, 20 + Math.floor(g / 50) * 11])
		root.get("Kids").push(w)
	}
	for (var t = 0; t < 15000; t++) fields.push(doc.addObject({ FT: Tx, T: doc.newString("Text" + t) }))
	doc.save(out + "/formbig.pdf", "compress")
}

// --- xmp.pdf: Info and matching XMP metadata, claiming PDF/A-2b ------------
function makeXMP() {
	var doc = newDocument()
	addTextPage(doc, LETTER, [[72, 90, 24, "Metadata"]])
	var info = doc.addObject({ Title: doc.newString("Old title"), Author: doc.newString("Old author"),
		Producer: doc.newString("make-corpus") })
	doc.getTrailer().put("Info", info)
	var xmp = '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' +
		'<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" pdfaid:part="2" pdfaid:conformance="B">' +
		'<dc:title><rdf:Alt><rdf:li xml:lang="x-default">Old title</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>'
	var stream = doc.addStream(xmp, { Type: doc.newName("Metadata"), Subtype: doc.newName("XML") })
	doc.getTrailer().get("Root").put("Metadata", stream)
	doc.save(out + "/xmp.pdf")
}

// --- content.pdf: text and images for Edit Content ---------------------------
// Page 1: a simple-font Tj, a kerned and coloured TJ, CID-font text,
// Type3 text, invisible text, text inside a Form XObject, one image drawn
// twice and an inline image. Page 2 is rotated, page 3 cropped.
function makeContent() {
	var doc = newDocument()
	var cid = doc.addFont(new Font("Helvetica"))
	var helv = new Font("Helvetica")
	function hex(s) {
		var out = "<"
		for (var i = 0; i < s.length; i++) {
			var g = helv.encodeCharacter(s.charCodeAt(i))
			out += ("0000" + g.toString(16)).slice(-4)
		}
		return out + ">"
	}
	var charproc = doc.addStream("500 0 0 0 400 400 d1 0 0 400 400 re f", {})
	var type3 = doc.addObject({ Type: doc.newName("Font"), Subtype: doc.newName("Type3"),
		FontBBox: [0, 0, 400, 400], FontMatrix: [0.001, 0, 0, 0.001, 0, 0],
		CharProcs: { a: charproc }, Encoding: { Type: doc.newName("Encoding"), Differences: [97, doc.newName("a")] },
		FirstChar: 97, LastChar: 97, Widths: [500], Resources: {} })
	var form = doc.addStream("BT /F1 12 Tf 0 0 Td (In a form) Tj ET",
		{ Type: doc.newName("XObject"), Subtype: doc.newName("Form"), BBox: [0, 0, 200, 50], Resources: { Font: { F1: doc.font } } })
	var pix = new Pixmap(ColorSpace.DeviceRGB, [0, 0, 4, 4], false)
	pix.clear(128)
	var image = doc.addImage(new Image(pix))
	var content =
		"BT /F1 24 Tf 72 700 Td (Hello world) Tj ET\n" +
		"BT /F1 18 Tf 1 0 0 rg 72 660 Td [(Ke) -200 (rning)] TJ 0 g ET\n" +
		"BT /F2 18 Tf 72 620 Td " + hex("Wide text") + " Tj ET\n" +
		"BT /F3 18 Tf 72 580 Td (aaa) Tj ET\n" +
		"BT /F1 12 Tf 3 Tr 300 580 Td (hidden) Tj 0 Tr ET\n" +
		"q 1 0 0 1 72 520 cm /Fm0 Do Q\n" +
		"q 100 0 0 50 72 400 cm /Im0 Do Q\n" +
		"q 50 0 0 50 300 400 cm /Im0 Do Q\n" +
		"q 20 0 0 20 400 300 cm BI /W 1 /H 1 /CS /G /BPC 8 ID \x80 EI Q\n"
	var page = doc.addPage(LETTER, 0, { Font: { F1: doc.font, F2: cid, F3: type3 }, XObject: { Fm0: form, Im0: image } }, content)
	doc.insertPage(-1, page)
	var rotated = doc.addPage(LETTER, 90, { Font: { F1: doc.font }, XObject: { Im0: image } },
		"BT /F1 24 Tf 72 700 Td (Turned) Tj ET\nq 100 0 0 50 72 400 cm /Im0 Do Q\n")
	doc.insertPage(-1, rotated)
	var cropped = doc.addPage(LETTER, 0, { Font: { F1: doc.font } }, "BT /F1 24 Tf 172 600 Td (Cropped) Tj ET\n")
	doc.insertPage(-1, cropped)
	doc.findPage(2).put("CropBox", [100, 100, 500, 700])
	doc.save(out + "/content.pdf", "compress")

	// A page with more operations than the limit, and deeply nested q's.
	doc = newDocument()
	var ops = []
	for (var j = 0; j < 1000; j++) ops.push("q")
	ops.push("BT /F1 12 Tf 72 700 Td (deep) Tj ET")
	for (var k = 0; k < 1000; k++) ops.push("Q")
	ops.push("BT /F1 2 Tf 10 10 Td")
	for (var i = 0; i < 210000; i++) ops.push("(a) Tj")
	ops.push("ET")
	page = doc.addPage(LETTER, 0, { Font: { F1: doc.font } }, ops.join("\n"))
	doc.insertPage(-1, page)
	doc.save(out + "/contentbomb.pdf", "compress")

	// From the 0.5.0 review: an inline image an edit can't keep (an indexed
	// colour space), stray EMCs before a stamp-like mark, and a font set
	// through an ExtGState.
	doc = newDocument()
	page = doc.addPage(LETTER, 0, { Font: { F1: doc.font } },
		"BT /F1 24 Tf 72 700 Td (Hello) Tj ET\nq 20 0 0 20 300 300 cm BI /W 1 /H 1 /CS [/I /RGB 1 <ff000000ff00>] /BPC 8 ID \x01 EI Q\n")
	doc.insertPage(-1, page)
	page = doc.addPage(LETTER, 0, { Font: { F1: doc.font } },
		"EMC EMC /Artifact <</OPDFStamp /Watermark>> BDC BT /F1 12 Tf 72 700 Td (mark) Tj ET EMC BT /F1 12 Tf 72 600 Td (after) Tj ET\n")
	doc.insertPage(-1, page)
	var gs = doc.addObject({ Type: doc.newName("ExtGState"), Font: [doc.font, 24] })
	page = doc.addPage(LETTER, 0, { Font: { F1: doc.font }, ExtGState: { GS0: gs } },
		"/GS0 gs BT 72 700 Td (gsfont) Tj ET\n")
	doc.insertPage(-1, page)
	doc.save(out + "/contentodd.pdf", "compress")
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
makeRedactLeftovers()
makeParagraphs()
makeParaBomb()
makeFormBomb()
makeXMP()
makeContent()
print("corpus: wrote the test PDFs to " + out)
