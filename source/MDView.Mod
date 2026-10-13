MODULE MDView; (** MD2AO viewer: a visual component with a toolbar (Home, Back, Forward) and a scrollable document page *)

IMPORT Commands, KernelLog, Streams, Inputs, WMComponents, WMStandardComponents, WMEditors, WMGraphics, WMRectangles,
	WMWindowManager, Strings, MDTree, MDParser, MDLayout, MDConfig, MDSource, MDClip, MDSearch;

(*
	Usage as a component:   NEW(view); IF view.Open("Help/Index.md") THEN END;   -- add view to any form or panel
	Usage as a window:      MDView.Show Help/Index.md ~

	The documents and pictures come from a Source (see MDSource); the default is the file system.
	Links: #anchor scrolls inside the page; page.md#anchor opens another page of the same source
	(relative to the current one) and scrolls to the anchor; links with a scheme (http:, mailto:, ...)
	are given to the navigate handler, or just logged.
	Fonts, colors and spacing come from MDStyles.XML if the file exists (see MDConfig).

	Search: the field on the right of the toolbar. Typing marks the words found on the page, Enter or Next
	goes to the next one, Shift+Enter or Prev to the previous one; "Find all" searches all pages of the help
	and shows the places found as a page of links.
	Keys (the page has the focus): Up, Down, Page Up, Page Down, Home, End and Space scroll; Alt+Left and
	Alt+Right are Back and Forward; Ctrl+F goes to the search field; F3 and Shift+F3 find next and previous;
	Escape clears the search.
*)

CONST
	DefaultStyleFile = "MDStyles.XML";
	MaxHistory = 64;
	SearchPrefix = "?search:";	(* the name of the page with the results of a search of the whole help *)

	(* what the page tells the viewer when a key is pressed *)
	KeyBack = 0; KeyForward = 1; KeyFind = 2; KeyEscape = 3;

TYPE
	(** called for links with a scheme (http:, mailto:, ...); dest is the link destination *)
	NavigateHandler* = PROCEDURE {DELEGATE} (sender: ANY; CONST dest: ARRAY OF CHAR);
	LinkHandler* = PROCEDURE {DELEGATE} (link: MDTree.Node);
	KeyHandler* = PROCEDURE {DELEGATE} (code: SIGNED32);
	(** current = the number of the marked place (0 if none), total = how many were found *)
	StatusHandler* = PROCEDURE {DELEGATE} (current, total: SIGNED32; active: BOOLEAN);
	TypedHandler = PROCEDURE {DELEGATE} (sender: ANY);

	(* the search field: a text field that tells after every key that the text has changed *)
	SearchField = OBJECT(WMEditors.TextField)
	VAR
		onTyped: TypedHandler;
		last: ARRAY 256 OF CHAR;
		shift: BOOLEAN;	(* Shift was held at the last key *)

		PROCEDURE Clear*;
		BEGIN
			SetAsString(""); last[0] := 0X
		END Clear;

		PROCEDURE KeyEvent*(ucs: SIZE; flags: SET; VAR keySym: SIZE);
		VAR now: ARRAY 256 OF CHAR;
		BEGIN
			shift := Inputs.Shift * flags # {};
			KeyEvent^(ucs, flags, keySym);
			IF ~(Inputs.Release IN flags) THEN
				GetAsString(now);
				IF ~(now = last) THEN
					COPY(now, last);
					IF onTyped # NIL THEN onTyped(SELF) END
				END
			END
		END KeyEvent;
	END SearchField;

	CacheEntry = OBJECT	(* a decoded picture of the current page; img = NIL if it could not be loaded *)
	VAR
		name: ARRAY 256 OF CHAR;
		img: WMGraphics.Image;
		next: CacheEntry;
	END CacheEntry;

	Entry = RECORD
		path: ARRAY 256 OF CHAR;
		scroll: SIZE;
	END;
	EntryArray = POINTER TO ARRAY OF Entry;

	(** the document pane: layout, drawing, scrolling, clicks on links *)
	Page* = OBJECT(WMComponents.VisualComponent)
	VAR
		styles*: MDLayout.Styles;
		source*: MDSource.Source;
		onLink*: LinkHandler;	(* links that are not anchors of this page *)
		onKey*: KeyHandler;	(* keys that belong to the whole viewer *)
		onStatus*: StatusHandler;	(* the number of places found changed *)
		query: ARRAY 256 OF CHAR;	(* the text that is marked on the page *)
		matches, current: MDLayout.Match;
		matchCount: SIGNED32;
		jump: BOOLEAN;	(* go to the first place found as soon as the page is laid out *)
		vsb: WMStandardComponents.Scrollbar;
		doc: MDTree.Node;
		layout: MDLayout.Layout;
		scrollY, step, pendingScroll: SIZE;	(* pixels above the view; scrollbar unit in pixels *)
		updating: BOOLEAN;
		downLink: MDTree.Node;
		downCopy, copied: MDLayout.Item;	(* the Copy button that was pressed / that shows "Copied" *)
		timer: WMStandardComponents.Timer;
		curPath: ARRAY 256 OF CHAR;
		anchorToShow: ARRAY 256 OF CHAR;
		cache: CacheEntry;

		PROCEDURE &Init*;
		BEGIN
			Init^;
			NEW(styles);
			IF MDConfig.Apply(styles, DefaultStyleFile) THEN END;	(* no file: built-in styles *)
			step := 20; scrollY := 0; pendingScroll := 0; updating := FALSE;
			doc := NIL; layout := NIL; downLink := NIL; cache := NIL; source := NIL; onLink := NIL;
			downCopy := NIL; copied := NIL;
			onKey := NIL; onStatus := NIL; query[0] := 0X; matches := NIL; current := NIL; matchCount := 0; jump := FALSE;
			curPath[0] := 0X; anchorToShow[0] := 0X;
			fillColor.Set(WMGraphics.White);
			NEW(vsb);
			vsb.vertical.Set(TRUE);
			vsb.alignment.Set(WMComponents.AlignRight);
			vsb.onPositionChanged.Add(ScrollChanged);
			AddContent(vsb);
			NEW(timer); timer.delay.Set(1500); timer.interval.Set(1500);
			timer.onTimer.Add(TimerTick); AddContent(timer);
			takesFocus.Set(TRUE)
		END Init;

		(* ---- pictures ---- *)

		PROCEDURE GetImage(CONST src: ARRAY OF CHAR): WMGraphics.Image;
		VAR full: ARRAY 256 OF CHAR; e: CacheEntry; r: Streams.Reader;
		BEGIN
			IF (source = NIL) OR (MDTree.LinkKind(src) = MDTree.LinkExternal) THEN RETURN NIL END;
			MDSource.Resolve(curPath, src, full);
			e := cache;
			WHILE (e # NIL) & ~(e.name = full) DO e := e.next END;
			IF e = NIL THEN
				NEW(e); COPY(full, e.name);
				r := source.Open(full);
				IF r = NIL THEN
					KernelLog.String("MDView: picture file not found: "); KernelLog.String(full); KernelLog.Ln
				ELSE
					e.img := MDSource.DecodeImage(r, full);
					IF e.img = NIL THEN
						KernelLog.String("MDView: picture could not be decoded: "); KernelLog.String(full); KernelLog.Ln
					END
				END;
				e.next := cache; cache := e
			END;
			RETURN e.img
		END GetImage;

		(* ---- layout and scrolling ---- *)

		PROCEDURE DoLayout;
		VAR w, h, maxScroll, units, ps: SIZE;
		BEGIN
			IF doc = NIL THEN layout := NIL; Invalidate; RETURN END;
			w := bounds.GetWidth() - vsb.bounds.GetWidth();
			h := bounds.GetHeight();
			IF (w < 40) OR (h < 10) THEN RETURN END;
			NEW(layout);
			layout.provider := SELF.GetImage;
			layout.Build(doc, styles, w);
			maxScroll := MAX(0, layout.height - h);
			IF scrollY > maxScroll THEN scrollY := maxScroll END;
			units := (maxScroll + step - 1) DIV step;
			ps := 1;
			IF layout.height > 0 THEN ps := MAX(1, ((h * maxScroll) DIV layout.height) DIV step) END;
			updating := TRUE;
			vsb.max.Set(units); vsb.pageSize.Set(ps); vsb.pos.Set(scrollY DIV step);
			updating := FALSE;
			IF anchorToShow[0] # 0X THEN
				GoToAnchor(anchorToShow);
				anchorToShow[0] := 0X
			ELSIF pendingScroll > 0 THEN
				ScrollTo(pendingScroll)
			END;
			pendingScroll := 0;
			Rescan;	(* the items are new: find the marked places again *)
			IF jump & (matches # NIL) THEN SelectFirst END;
			jump := FALSE;
			Invalidate
		END DoLayout;

		PROCEDURE LayoutEvent(sender, data: ANY);
		BEGIN
			DoLayout
		END LayoutEvent;

		PROCEDURE RequestLayout;
		BEGIN
			IF sequencer = NIL THEN
				(* not in a window yet: Initialize will do the layout *)
			ELSIF IsCallFromSequencer() THEN
				DoLayout
			ELSE
				sequencer.ScheduleEvent(SELF.LayoutEvent, NIL, NIL)
			END
		END RequestLayout;

		(** lays the page out again, for example after the styles have changed *)
		PROCEDURE Relayout*;
		BEGIN
			RequestLayout
		END Relayout;

		PROCEDURE Initialize*;
		BEGIN
			Initialize^;
			DoLayout
		END Initialize;

		PROCEDURE Resized*;
		BEGIN
			Resized^;
			DoLayout
		END Resized;

		PROCEDURE ScrollTo(y: SIZE);
		VAR maxScroll: SIZE;
		BEGIN
			IF layout = NIL THEN RETURN END;
			maxScroll := MAX(0, layout.height - bounds.GetHeight());
			IF y > maxScroll THEN y := maxScroll END;
			IF y < 0 THEN y := 0 END;
			scrollY := y;
			updating := TRUE;
			vsb.pos.Set(scrollY DIV step);
			updating := FALSE;
			Invalidate
		END ScrollTo;

		(** the scroll position in pixels, to be restored later with SetDocument *)
		PROCEDURE GetScroll*(): SIZE;
		BEGIN
			RETURN scrollY
		END GetScroll;

		PROCEDURE SetScroll*(y: SIZE);
		BEGIN
			ScrollTo(y)
		END SetScroll;

		PROCEDURE ScrollChanged(sender, data: ANY);
		VAR maxScroll: SIZE;
		BEGIN
			IF updating OR (layout = NIL) THEN RETURN END;
			maxScroll := MAX(0, layout.height - bounds.GetHeight());
			scrollY := MIN(vsb.pos.Get() * step, maxScroll);
			Invalidate
		END ScrollChanged;

		PROCEDURE WheelMove*(dz: SIZE);
		BEGIN
			ScrollTo(scrollY + dz * 3 * step)
		END WheelMove;

		(* ---- documents and links ---- *)

		(** shows a parsed document; path is its name inside the source (for relative links);
		    the page scrolls to the anchor if it is not empty, else to the scroll position *)
		PROCEDURE SetDocument*(d: MDTree.Node; CONST path, anchor: ARRAY OF CHAR; scroll: SIZE);
		BEGIN
			doc := d; COPY(path, curPath); COPY(anchor, anchorToShow);
			pendingScroll := scroll; scrollY := 0; layout := NIL; cache := NIL; copied := NIL;
			RequestLayout
		END SetDocument;

		PROCEDURE GoToAnchor*(CONST frag: ARRAY OF CHAR);
		VAR slug: ARRAY 256 OF CHAR; top: SIZE;
		BEGIN
			IF frag[0] = 0X THEN RETURN END;
			MDTree.Slugify(frag, slug);
			IF (layout # NIL) & layout.FindAnchor(slug, top) THEN ScrollTo(top - 4) END
		END GoToAnchor;

		PROCEDURE Activate(link: MDTree.Node);
		VAR path, frag: ARRAY 256 OF CHAR;
		BEGIN
			IF link.dest = NIL THEN RETURN END;
			IF MDTree.LinkKind(link.dest^) = MDTree.LinkAnchor THEN
				MDTree.SplitDest(link.dest^, path, frag);
				GoToAnchor(frag)
			ELSIF onLink # NIL THEN
				onLink(link)
			END
		END Activate;

		PROCEDURE LinkAtPointer(x, y: SIZE): MDTree.Node;
		BEGIN
			IF layout = NIL THEN RETURN NIL END;
			RETURN layout.LinkAt(x, y + scrollY)
		END LinkAtPointer;

		PROCEDURE CopyAtPointer(x, y: SIZE): MDLayout.Item;
		BEGIN
			IF layout = NIL THEN RETURN NIL END;
			RETURN layout.CopyAt(x, y + scrollY)
		END CopyAtPointer;

		(* the caption "Copied" goes away after a moment; the timer runs in its own thread *)
		PROCEDURE TimerTick(sender, data: ANY);
		BEGIN
			timer.Stop(SELF, NIL);
			IF sequencer # NIL THEN sequencer.ScheduleEvent(SELF.ClearCopied, NIL, NIL) END
		END TimerTick;

		PROCEDURE ClearCopied(sender, data: ANY);
		BEGIN
			copied := NIL;
			Invalidate
		END ClearCopied;

		PROCEDURE PointerDown*(x, y: SIZE; keys: SET);
		BEGIN
			PointerDown^(x, y, keys);
			SetFocus;
			IF 0 IN keys THEN
				downLink := LinkAtPointer(x, y);
				downCopy := CopyAtPointer(x, y)
			END
		END PointerDown;

		PROCEDURE PointerUp*(x, y: SIZE; keys: SET);
		VAR link: MDTree.Node; btn: MDLayout.Item;
		BEGIN
			PointerUp^(x, y, keys);
			link := downLink; downLink := NIL;
			btn := downCopy; downCopy := NIL;
			IF (link # NIL) & (LinkAtPointer(x, y) = link) THEN Activate(link) END;
			IF (btn # NIL) & (CopyAtPointer(x, y) = btn) & (btn.text # NIL) THEN
				MDClip.Put(btn.text^);
				copied := btn;
				timer.Start(SELF, NIL);
				Invalidate
			END
		END PointerUp;

		(* ---- searching in the page ---- *)

		PROCEDURE ReportStatus;
		VAR m: MDLayout.Match; idx: SIGNED32;
		BEGIN
			idx := 0;
			IF current # NIL THEN
				idx := 1; m := matches;
				WHILE (m # NIL) & (m # current) DO INC(idx); m := m.next END
			END;
			IF onStatus # NIL THEN onStatus(idx, matchCount, query[0] # 0X) END
		END ReportStatus;

		(* finds the marked places again in the layout *)
		PROCEDURE Rescan;
		VAR m: MDLayout.Match;
		BEGIN
			matches := NIL; current := NIL; matchCount := 0;
			IF (layout # NIL) & (query[0] # 0X) THEN
				matches := layout.Find(query);
				m := matches;
				WHILE m # NIL DO INC(matchCount); m := m.next END
			END;
			ReportStatus
		END Rescan;

		(* makes m the current place and scrolls to it if it is not in view *)
		PROCEDURE ShowMatch(m: MDLayout.Match);
		VAR h: SIZE;
		BEGIN
			current := m; h := bounds.GetHeight();
			IF (m.y < scrollY + step) OR (m.y > scrollY + h - 3 * step) THEN ScrollTo(m.y - h DIV 4) END;
			ReportStatus;
			Invalidate
		END ShowMatch;

		(* the first place at or below the top of the view *)
		PROCEDURE SelectFirst;
		VAR m: MDLayout.Match;
		BEGIN
			m := matches;
			WHILE (m # NIL) & (m.y + 2 < scrollY) DO m := m.next END;
			IF m = NIL THEN m := matches END;
			IF m # NIL THEN ShowMatch(m) END
		END SelectFirst;

		(** marks every place of the page where q is found (case does not matter); jumpTo: go to the first one *)
		PROCEDURE SetQuery*(CONST q: ARRAY OF CHAR; jumpTo: BOOLEAN);
		BEGIN
			COPY(q, query);
			Rescan;
			IF jumpTo & (matches # NIL) THEN SelectFirst END;
			Invalidate
		END SetQuery;

		(** the next page that is shown marks q and goes to the first place found on it (after its anchor) *)
		PROCEDURE ArmQuery*(CONST q: ARRAY OF CHAR);
		BEGIN
			COPY(q, query); jump := TRUE
		END ArmQuery;

		PROCEDURE FindNext*;
		BEGIN
			IF matches = NIL THEN RETURN END;
			IF current = NIL THEN SelectFirst
			ELSIF current.next # NIL THEN ShowMatch(current.next)
			ELSE ShowMatch(matches)	(* after the last one comes the first *)
			END
		END FindNext;

		PROCEDURE FindPrev*;
		VAR m, p: MDLayout.Match;
		BEGIN
			IF matches = NIL THEN RETURN END;
			p := NIL;
			IF current = NIL THEN	(* the last place above the view *)
				m := matches;
				WHILE (m # NIL) & (m.y < scrollY - 1) DO p := m; m := m.next END
			ELSE
				m := matches;
				WHILE (m # NIL) & (m # current) DO p := m; m := m.next END
			END;
			IF p = NIL THEN	(* before the first one comes the last one *)
				p := matches;
				WHILE p.next # NIL DO p := p.next END
			END;
			ShowMatch(p)
		END FindPrev;

		(* ---- keys ---- *)

		PROCEDURE KeyEvent*(ucs: SIZE; flags: SET; VAR keySym: SIZE);
		VAR h: SIZE; alt, ctrl, shift: BOOLEAN;
		BEGIN
			IF Inputs.Release IN flags THEN RETURN END;
			alt := Inputs.Alt * flags # {}; ctrl := Inputs.Ctrl * flags # {}; shift := Inputs.Shift * flags # {};
			h := bounds.GetHeight();
			IF alt & (keySym = Inputs.KsLeft) THEN
				IF onKey # NIL THEN onKey(KeyBack) END
			ELSIF alt & (keySym = Inputs.KsRight) THEN
				IF onKey # NIL THEN onKey(KeyForward) END
			ELSIF ctrl & (keySym = 06H) THEN	(* Ctrl-F *)
				IF onKey # NIL THEN onKey(KeyFind) END
			ELSIF keySym = Inputs.KsF3 THEN
				IF shift THEN FindPrev ELSE FindNext END
			ELSIF keySym = Inputs.KsEscape THEN
				SetQuery("", FALSE);
				IF onKey # NIL THEN onKey(KeyEscape) END
			ELSIF keySym = Inputs.KsDown THEN
				ScrollTo(scrollY + step)
			ELSIF keySym = Inputs.KsUp THEN
				ScrollTo(scrollY - step)
			ELSIF keySym = 0FF56H THEN	(* Page Down *)
				ScrollTo(scrollY + h - 2 * step)
			ELSIF keySym = 0FF55H THEN	(* Page Up *)
				ScrollTo(scrollY - (h - 2 * step))
			ELSIF keySym = 0FF50H THEN	(* Home *)
				ScrollTo(0)
			ELSIF keySym = 0FF57H THEN	(* End *)
				IF layout # NIL THEN ScrollTo(layout.height) END
			ELSIF (keySym = 20H) & ~ctrl & ~alt THEN	(* Space, Shift+Space *)
				IF shift THEN ScrollTo(scrollY - (h - 2 * step)) ELSE ScrollTo(scrollY + h - 2 * step) END
			END
		END KeyEvent;

		(* ---- drawing ---- *)

		PROCEDURE DrawBackground*(canvas: WMGraphics.Canvas);
		VAR it: MDLayout.Item; clip: WMRectangles.Rectangle; top, asc, tw, th: SIZE; caption: ARRAY 8 OF CHAR;
			m: MDLayout.Match; done: BOOLEAN; hl: WMGraphics.Color;
		BEGIN
			DrawBackground^(canvas);
			IF layout = NIL THEN RETURN END;
			canvas.GetClipRect(clip);
			m := matches;	(* the places found, under the text *)
			WHILE m # NIL DO
				IF m = current THEN hl := WMGraphics.RGBAToColor(255, 170, 60, 255)
				ELSE hl := WMGraphics.RGBAToColor(255, 235, 100, 255)
				END;
				it := m.first; done := FALSE;
				WHILE (it # NIL) & ~done DO
					IF (it.kind = MDLayout.ItemText) & (it.text # NIL) THEN
						top := it.y - scrollY;
						IF (top + it.h >= clip.t) & (top <= clip.b) THEN
							canvas.Fill(WMRectangles.MakeRect(it.x, top, it.x + it.w, top + it.h), hl, WMGraphics.ModeSrcOverDst)
						END
					END;
					IF it = m.last THEN done := TRUE ELSE it := it.next END
				END;
				m := m.next
			END;
			it := layout.first;
			WHILE it # NIL DO
				top := it.y - scrollY;
				IF (top + it.h >= clip.t) & (top <= clip.b) THEN
					IF it.kind = MDLayout.ItemRect THEN
						canvas.Fill(WMRectangles.MakeRect(it.x, top, it.x + it.w, top + it.h), it.color, WMGraphics.ModeSrcOverDst)
					ELSIF it.kind = MDLayout.ItemCopy THEN	(* the button of a code block *)
						canvas.Fill(WMRectangles.MakeRect(it.x, top, it.x + it.w, top + it.h),
							WMGraphics.RGBAToColor(150, 150, 150, 255), WMGraphics.ModeSrcOverDst);
						IF it = copied THEN
							canvas.Fill(WMRectangles.MakeRect(it.x + 1, top + 1, it.x + it.w - 1, top + it.h - 1),
								WMGraphics.RGBAToColor(200, 235, 200, 255), WMGraphics.ModeSrcOverDst);
							caption := "Copied"
						ELSE
							canvas.Fill(WMRectangles.MakeRect(it.x + 1, top + 1, it.x + it.w - 1, top + it.h - 1),
								WMGraphics.White, WMGraphics.ModeSrcOverDst);
							caption := "Copy"
						END;
						it.font.GetStringSize(caption, tw, th);
						canvas.SetFont(it.font); canvas.SetColor(it.color);
						canvas.DrawString(it.x + (it.w - tw) DIV 2, top + (it.h - it.font.GetHeight()) DIV 2 + it.font.GetAscent(), caption)
					ELSIF it.kind = MDLayout.ItemImage THEN
						IF (it.image.width = it.w) & (it.image.height = it.h) THEN
							canvas.DrawImage(it.x, top, it.image, WMGraphics.ModeSrcOverDst)
						ELSE
							canvas.ScaleImage(it.image, WMRectangles.MakeRect(0, 0, it.image.width, it.image.height),
								WMRectangles.MakeRect(it.x, top, it.x + it.w, top + it.h),
								WMGraphics.ModeSrcOverDst, WMGraphics.ScaleBilinear)
						END
					ELSE
						asc := it.font.GetAscent();
						canvas.SetFont(it.font); canvas.SetColor(it.color);
						canvas.DrawString(it.x, top + asc, it.text^);
						IF it.link # NIL THEN
							canvas.Line(it.x, top + asc + 1, it.x + it.w - 1, top + asc + 1, it.color, WMGraphics.ModeSrcOverDst)
						END
					END
				END;
				it := it.next
			END
		END DrawBackground;

	END Page;

	(** the viewer: a toolbar with Home / Back / Forward above a Page, and the history of visited pages *)
	View* = OBJECT(WMComponents.VisualComponent)
	VAR
		toolbar: WMStandardComponents.Panel;
		btnHome, btnBack, btnFwd, btnPrev, btnNext, btnAll: WMStandardComponents.Button;
		box: SearchField;	(* the search field *)
		status: WMStandardComponents.Label;	(* how many places were found *)
		searchQuery: ARRAY 256 OF CHAR;	(* what the last search of the whole help looked for *)
		page: Page;
		source: MDSource.Source;
		navigate: NavigateHandler;
		home: ARRAY 256 OF CHAR;
		hist: EntryArray;
		histCount, histPos: SIGNED32;

		PROCEDURE &Init*;
		BEGIN
			Init^;
			NEW(hist, MaxHistory); histCount := 0; histPos := -1;
			home[0] := 0X; navigate := NIL; source := NIL;
			NEW(toolbar);
			toolbar.alignment.Set(WMComponents.AlignTop); toolbar.bounds.SetHeight(30);
			toolbar.fillColor.Set(WMGraphics.RGBAToColor(224, 224, 224, 255));
			AddContent(toolbar);
			NEW(btnHome); btnHome.caption.SetAOC("Home");
			btnHome.alignment.Set(WMComponents.AlignLeft); btnHome.bounds.SetWidth(72);
			btnHome.onClick.Add(HomeClicked); toolbar.AddContent(btnHome);
			NEW(btnBack); btnBack.caption.SetAOC("Back");
			btnBack.alignment.Set(WMComponents.AlignLeft); btnBack.bounds.SetWidth(72);
			btnBack.onClick.Add(BackClicked); toolbar.AddContent(btnBack);
			NEW(btnFwd); btnFwd.caption.SetAOC("Forward");
			btnFwd.alignment.Set(WMComponents.AlignLeft); btnFwd.bounds.SetWidth(72);
			btnFwd.onClick.Add(ForwardClicked); toolbar.AddContent(btnFwd);
			(* the search: the right-aligned parts are added from the right edge to the left, the field takes the rest *)
			NEW(btnAll); btnAll.caption.SetAOC("Find all");
			btnAll.alignment.Set(WMComponents.AlignRight); btnAll.bounds.SetWidth(84);
			btnAll.onClick.Add(AllClicked); toolbar.AddContent(btnAll);
			NEW(btnNext); btnNext.caption.SetAOC("Next");
			btnNext.alignment.Set(WMComponents.AlignRight); btnNext.bounds.SetWidth(56);
			btnNext.onClick.Add(NextClicked); toolbar.AddContent(btnNext);
			NEW(btnPrev); btnPrev.caption.SetAOC("Prev");
			btnPrev.alignment.Set(WMComponents.AlignRight); btnPrev.bounds.SetWidth(56);
			btnPrev.onClick.Add(PrevClicked); toolbar.AddContent(btnPrev);
			NEW(status); status.alignment.Set(WMComponents.AlignRight); status.bounds.SetWidth(70);
			toolbar.AddContent(status);
			NEW(box); box.alignment.Set(WMComponents.AlignClient);
			box.fillColor.Set(WMGraphics.White);
			box.onEnter.Add(BoxEnter); box.onEscape.Add(BoxEscape); box.onTyped := SELF.BoxTyped;
			toolbar.AddContent(box);
			searchQuery[0] := 0X;
			NEW(page); page.alignment.Set(WMComponents.AlignClient);
			page.onLink := SELF.LinkClicked;
			page.onKey := SELF.PageKey; page.onStatus := SELF.PageStatus;
			AddContent(page);
			UpdateButtons
		END Init;

		PROCEDURE Initialize*;
		BEGIN
			Initialize^;
			page.SetFocus	(* the keys scroll the page from the start *)
		END Initialize;

		(* ---- history ---- *)

		PROCEDURE UpdateButtons;
		BEGIN
			btnBack.enabled.Set(histPos > 0);
			btnFwd.enabled.Set(histPos < histCount - 1);
			btnHome.enabled.Set(histCount > 0)
		END UpdateButtons;

		(* a new page after the current one; the pages that were ahead are forgotten *)
		PROCEDURE Push(CONST path: ARRAY OF CHAR);
		VAR i: SIGNED32;
		BEGIN
			histCount := histPos + 1;
			IF histCount = LEN(hist) THEN
				FOR i := 1 TO histCount - 1 DO hist[i - 1] := hist[i] END;
				DEC(histCount)
			END;
			COPY(path, hist[histCount].path); hist[histCount].scroll := 0;
			histPos := histCount; INC(histCount)
		END Push;

		(* reads, parses and shows a page; FALSE if the file cannot be read *)
		PROCEDURE Display(CONST path, anchor: ARRAY OF CHAR; scroll: SIZE): BOOLEAN;
		VAR r: Streams.Reader; d: MDTree.Node; q: ARRAY 256 OF CHAR;
		BEGIN
			IF source = NIL THEN RETURN FALSE END;
			IF IsSearchPath(path, q) THEN	(* not a file: the places found in the whole help *)
				COPY(q, searchQuery);
				d := MDSearch.Run(source, home, q);
				page.source := source;
				page.SetQuery("", FALSE);
				page.SetDocument(d, path, anchor, scroll);
				RETURN TRUE
			END;
			r := source.Open(path);
			IF r = NIL THEN RETURN FALSE END;
			d := MDParser.Parse(r);
			page.source := source;
			page.SetDocument(d, path, anchor, scroll);
			RETURN TRUE
		END Display;

		(* follows a link to another page: the current one is left in the history *)
		PROCEDURE GoTo(CONST path, anchor: ARRAY OF CHAR);
		BEGIN
			IF histPos >= 0 THEN hist[histPos].scroll := page.GetScroll() END;
			IF Display(path, anchor, 0) THEN
				Push(path)
			ELSE
				KernelLog.String("MDView: cannot open "); KernelLog.String(path); KernelLog.Ln
			END;
			UpdateButtons
		END GoTo;

		(** the page where the last Open started *)
		PROCEDURE Home*;
		BEGIN
			IF home[0] = 0X THEN RETURN END;
			IF (histPos >= 0) & (hist[histPos].path = home) THEN
				page.SetScroll(0)
			ELSE
				GoTo(home, "")
			END
		END Home;

		PROCEDURE Back*;
		BEGIN
			IF histPos <= 0 THEN RETURN END;
			hist[histPos].scroll := page.GetScroll();
			IF Display(hist[histPos - 1].path, "", hist[histPos - 1].scroll) THEN DEC(histPos) END;
			UpdateButtons
		END Back;

		PROCEDURE Forward*;
		BEGIN
			IF histPos >= histCount - 1 THEN RETURN END;
			hist[histPos].scroll := page.GetScroll();
			IF Display(hist[histPos + 1].path, "", hist[histPos + 1].scroll) THEN INC(histPos) END;
			UpdateButtons
		END Forward;

		PROCEDURE HomeClicked(sender, data: ANY);
		BEGIN
			Home; page.SetFocus
		END HomeClicked;

		PROCEDURE BackClicked(sender, data: ANY);
		BEGIN
			Back; page.SetFocus
		END BackClicked;

		PROCEDURE ForwardClicked(sender, data: ANY);
		BEGIN
			Forward; page.SetFocus
		END ForwardClicked;

		(* ---- search ---- *)

		(* a key was pressed in the search field *)
		PROCEDURE BoxTyped(sender: ANY);
		VAR q: ARRAY 256 OF CHAR;
		BEGIN
			box.GetAsString(q);
			page.SetQuery(q, TRUE)
		END BoxTyped;

		PROCEDURE BoxEnter(sender, data: ANY);
		VAR q: ARRAY 256 OF CHAR;
		BEGIN
			box.GetAsString(q);
			page.SetQuery(q, FALSE);	(* in case the text was changed in some other way *)
			IF box.shift THEN page.FindPrev ELSE page.FindNext END
		END BoxEnter;

		PROCEDURE BoxEscape(sender, data: ANY);
		BEGIN
			box.Clear;
			page.SetQuery("", FALSE);
			page.SetFocus
		END BoxEscape;

		PROCEDURE PrevClicked(sender, data: ANY);
		BEGIN
			page.FindPrev; page.SetFocus
		END PrevClicked;

		PROCEDURE NextClicked(sender, data: ANY);
		BEGIN
			page.FindNext; page.SetFocus
		END NextClicked;

		(* the places found in the whole help become a page of links; it is a step of the history *)
		PROCEDURE SearchAll;
		VAR q, path: ARRAY 256 OF CHAR;
		BEGIN
			box.GetAsString(q);
			IF q[0] = 0X THEN box.SetFocus; RETURN END;
			COPY(SearchPrefix, path); AppendStr(path, q);
			IF histPos >= 0 THEN hist[histPos].scroll := page.GetScroll() END;
			IF Display(path, "", 0) THEN Push(path) END;
			UpdateButtons;
			page.SetFocus
		END SearchAll;

		PROCEDURE AllClicked(sender, data: ANY);
		BEGIN
			SearchAll
		END AllClicked;

		(* a key of the whole viewer was pressed while the page had the focus *)
		PROCEDURE PageKey(code: SIGNED32);
		BEGIN
			IF code = KeyBack THEN Back
			ELSIF code = KeyForward THEN Forward
			ELSIF code = KeyFind THEN box.SetFocus
			ELSIF code = KeyEscape THEN box.Clear
			END
		END PageKey;

		(* the counter next to the search field *)
		PROCEDURE PageStatus(cur, total: SIGNED32; active: BOOLEAN);
		VAR s, n: ARRAY 32 OF CHAR;
		BEGIN
			s[0] := 0X;
			IF active THEN
				IF total = 0 THEN
					COPY("none", s)
				ELSE
					IF cur > 0 THEN IntToStr(cur, n); AppendStr(s, n); AppendStr(s, " / ") END;
					IntToStr(total, n); AppendStr(s, n)
				END
			END;
			status.caption.SetAOC(s)
		END PageStatus;

		(* ---- links ---- *)

		PROCEDURE LinkClicked(link: MDTree.Node);
		VAR path, frag, full, q: ARRAY 256 OF CHAR;
		BEGIN
			IF link.dest = NIL THEN RETURN END;
			IF MDTree.LinkKind(link.dest^) = MDTree.LinkPage THEN
				MDTree.SplitDest(link.dest^, path, frag);
				MDSource.Resolve(hist[histPos].path, path, full);
				IF IsSearchPath(hist[histPos].path, q) THEN
					page.ArmQuery(q)	(* from the results: mark the words and go to the first one *)
				ELSE
					page.SetQuery("", FALSE)
				END;
				GoTo(full, frag)
			ELSIF navigate # NIL THEN
				navigate(SELF, link.dest^)
			ELSE
				KernelLog.String("MDView: link "); KernelLog.String(link.dest^); KernelLog.Ln
			END
		END LinkClicked;

		(* ---- interface ---- *)

		(** the files come from this source; the default is the file system *)
		PROCEDURE SetSource*(s: MDSource.Source);
		BEGIN
			source := s
		END SetSource;

		(** shows a page of the source and makes it the home page; the history starts anew.
		    target is a file name, optionally with an anchor: "usage.md" or "usage.md#installation" *)
		PROCEDURE Open*(CONST target: ARRAY OF CHAR): BOOLEAN;
		VAR fs: MDSource.FileSource; path, frag: ARRAY 256 OF CHAR;
		BEGIN
			IF source = NIL THEN NEW(fs, ""); source := fs END;
			MDTree.SplitDest(target, path, frag);
			COPY(path, home); histPos := -1; histCount := 0;
			IF Display(path, frag, 0) THEN
				Push(path); UpdateButtons;
				RETURN TRUE
			END;
			UpdateButtons;
			RETURN FALSE
		END Open;

		(** shows a help archive (ZIP) starting at a page, for example "usage.md" or "usage.md#installation";
		    an empty startPage means "index.md". Home leads to "index.md" if the archive has one.
		    MDStyles.XML inside the archive, if there is one, sets fonts, colors and spacing *)
		PROCEDURE OpenArchive*(CONST file, startPage: ARRAY OF CHAR): BOOLEAN;
		VAR src: MDSource.Source; r: Streams.Reader; first: ARRAY 256 OF CHAR; ok: BOOLEAN;
		BEGIN
			src := MDSource.OpenZip(file);
			IF src = NIL THEN RETURN FALSE END;
			source := src;
			r := source.Open(DefaultStyleFile);
			IF r # NIL THEN IF MDConfig.ApplyReader(page.styles, r) THEN END END;
			IF startPage[0] = 0X THEN COPY("index.md", first) ELSE COPY(startPage, first) END;
			ok := Open(first);
			IF ok & (source.Open("index.md") # NIL) THEN COPY("index.md", home) END;
			RETURN ok
		END OpenArchive;

		(** reads fonts, colors and spacing from a style file (see MDConfig) and lays the page out again *)
		PROCEDURE LoadStyles*(CONST file: ARRAY OF CHAR): BOOLEAN;
		VAR ok: BOOLEAN;
		BEGIN
			ok := MDConfig.Apply(page.styles, file);
			IF ok THEN page.Relayout END;
			RETURN ok
		END LoadStyles;

		PROCEDURE SetNavigateHandler*(h: NavigateHandler);
		BEGIN
			navigate := h
		END SetNavigateHandler;

	END View;

(* d := d + s, as far as it fits *)
PROCEDURE AppendStr(VAR d: ARRAY OF CHAR; CONST s: ARRAY OF CHAR);
VAR i, k: SIGNED32;
BEGIN
	i := 0; WHILE d[i] # 0X DO INC(i) END;
	k := 0;
	WHILE (s[k] # 0X) & (i < LEN(d) - 1) DO d[i] := s[k]; INC(i); INC(k) END;
	d[i] := 0X
END AppendStr;

PROCEDURE IntToStr(v: SIGNED32; VAR s: ARRAY OF CHAR);
VAR digits: ARRAY 12 OF CHAR; n, i: SIGNED32;
BEGIN
	n := 0;
	REPEAT digits[n] := CHR(ORD('0') + v MOD 10); INC(n); v := v DIV 10 UNTIL v = 0;
	i := 0;
	WHILE n > 0 DO DEC(n); s[i] := digits[n]; INC(i) END;
	s[i] := 0X
END IntToStr;

(* is path the name of the page with search results ("?search:text")? the text goes to q *)
PROCEDURE IsSearchPath(CONST path: ARRAY OF CHAR; VAR q: ARRAY OF CHAR): BOOLEAN;
VAR prefix: ARRAY 16 OF CHAR; i, k: SIGNED32;
BEGIN
	COPY(SearchPrefix, prefix);
	i := 0;
	WHILE (prefix[i] # 0X) & (path[i] = prefix[i]) DO INC(i) END;
	IF prefix[i] # 0X THEN q[0] := 0X; RETURN FALSE END;
	k := 0;
	WHILE (path[i] # 0X) & (k < LEN(q) - 1) DO q[k] := path[i]; INC(i); INC(k) END;
	q[k] := 0X;
	RETURN TRUE
END IsSearchPath;

(** MDView.Show file.md ~  -- opens a window with the document *)
PROCEDURE Show*(context: Commands.Context);
VAR name: ARRAY 256 OF CHAR; view: View; window: WMComponents.FormWindow;
BEGIN
	IF context.arg.GetString(name) THEN
		NEW(view);
		view.bounds.Set(WMRectangles.MakeRect(0, 0, 700, 500));
		IF view.Open(name) THEN
			NEW(window, 700, 500, FALSE);
			window.SetContent(view);
			window.SetTitle(Strings.NewString(name));
			WMWindowManager.ExtAddWindow(window, 100, 100,
				{WMWindowManager.FlagFrame, WMWindowManager.FlagClose, WMWindowManager.FlagMinimize, WMWindowManager.FlagMaximize})
		ELSE
			context.error.String("MDView: cannot open "); context.error.String(name); context.error.Ln
		END
	ELSE
		context.error.String("usage: MDView.Show file.md ~"); context.error.Ln
	END;
	context.error.Update
END Show;

(** MDView.ShowArchive help.zip [page.md] ~  -- opens a window with a help archive; the page defaults to index.md *)
PROCEDURE ShowArchive*(context: Commands.Context);
VAR name, start: ARRAY 256 OF CHAR; view: View; window: WMComponents.FormWindow;
BEGIN
	IF context.arg.GetString(name) THEN
		IF ~context.arg.GetString(start) THEN start[0] := 0X END;
		NEW(view);
		view.bounds.Set(WMRectangles.MakeRect(0, 0, 700, 500));
		IF view.OpenArchive(name, start) THEN
			NEW(window, 700, 500, FALSE);
			window.SetContent(view);
			window.SetTitle(Strings.NewString(name));
			WMWindowManager.ExtAddWindow(window, 100, 100,
				{WMWindowManager.FlagFrame, WMWindowManager.FlagClose, WMWindowManager.FlagMinimize, WMWindowManager.FlagMaximize})
		ELSE
			context.error.String("MDView: cannot open archive "); context.error.String(name); context.error.Ln
		END
	ELSE
		context.error.String("usage: MDView.ShowArchive help.zip [page.md] ~"); context.error.Ln
	END;
	context.error.Update
END ShowArchive;

(** MDView.CheckFont name size ~  -- tells which Ukrainian/Russian letters a font really contains.
    Without parameters the default font of the system is checked. *)
PROCEDURE CheckFont*(context: Commands.Context);
VAR name: ARRAY 128 OF CHAR; size: SIGNED32; font: WMGraphics.Font; codes: ARRAY 13 OF SIGNED32; i: SIGNED32;
BEGIN
	IF context.arg.GetString(name) & context.arg.GetInteger(size, FALSE) THEN
		font := WMGraphics.GetFont(name, size, {})
	ELSE
		font := WMGraphics.GetDefaultFont()
	END;
	context.out.String("font: "); context.out.String(font.name);
	context.out.String(", size "); context.out.Int(font.size, 0); context.out.Ln;
	codes[0] := 0410H; codes[1] := 042FH; codes[2] := 0430H; codes[3] := 044FH;
	codes[4] := 0404H; codes[5] := 0454H; codes[6] := 0406H; codes[7] := 0456H;
	codes[8] := 0407H; codes[9] := 0457H; codes[10] := 0490H; codes[11] := 0491H;
	codes[12] := 0401H;
	FOR i := 0 TO 12 DO
		context.out.String("U+"); context.out.Hex(codes[i], 4); context.out.String(": ");
		IF font.HasChar(codes[i]) THEN context.out.String("yes") ELSE context.out.String("NO") END;
		context.out.Ln
	END;
	context.out.Update
END CheckFont;

END MDView.


Compiler.Compile MD4AO/MDTree.Mod MD4AO/MDInline.Mod MD4AO/MDParser.Mod MD4AO/MDSource.Mod MD4AO/MDSearch.Mod MD4AO/MDHighlight.Mod 
MD4AO/MDMath.Mod MD4AO/MDLayout.Mod MD4AO/MDConfig.Mod MD4AO/MDClip.Mod MD4AO/MDView.Mod ~

MDView.ShowArchive MD2AO-demo.zip ~

System.Free MDView MDClip MDConfig MDLayout MDSearch MDMath MDHighlight MDSource MDParser MDInline MDTree ~
