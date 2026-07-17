skin{
	meta{
		name : "Nordic";
		description : "Nord-palette dark theme (gnome-look Nordic inspired)";
		author : "minia2";
		date : "2026-07-17";
	}
	window{
		useBitmaps : true;
		title{
			activeLeftMargin : 8;
			activeTopMargin : 16;
			activeColor : 0ECEFF4FF;
			activeCloseBitmap : "images/aclose.png";
			hoverCloseBitmap : "images/hclose.png";
			inactiveLeftMargin : 8;
			inactiveTopMargin : 16;
			inactiveColor : 0D8DEE9FF;
			inactiveCloseBitmap : "images/iclose.png";
		}
		top{
			activeLeft : "images/atl.png";
			activeMiddle : "images/atm.png";
			activeRight : "images/atr.png";
			inactiveMiddle : "images/itm.png";
		}
		bottom{
			activeLeft : "images/abl.png";
			activeMiddle : "images/abm.png";
			activeRight : "images/abr.png";
		}
		left{ activeMiddle : "images/alm.png"; }
		right{ activeMiddle : "images/arm.png"; }
		desktop{
			color : 088C0D0FF;
			bgColor : 02E3440FF;
			fgColor : 0ECEFF4FF;
			selectColor : 05E81ACFF;
		}
	}
	cursor{
		default{ bitmap : "images/arrow.png"; hotX : 0; hotY : 0; }
		move{ bitmap : "images/move.png"; hotX : 10; hotY : 10; }
	}
	component{
		button{
			bounds{ height : 22; width : 64; }
			clDefault : 0434C5EFF;
			clHover : 04C566AFF;
			clPressed : 05E81ACFF;
			clTextDefault : 0ECEFF4FF;
			clTextHover : 0ECEFF4FF;
			clTextPressed : 0ECEFF4FF;
			fontHeight : 12;
			effect3d : 0;
			useBgBitmaps : FALSE;
		}
		scrollbar{
			width : 14;
			minTrackerSize : 40;
			useTrackerBitmaps : FALSE;
			useArrowBitmaps : FALSE;
			useBackgroundBitmaps : FALSE;
			clDefault : 03B4252FF;
			clHover : 0434C5EFF;
			clPressed : 05E81ACFF;
			clBtnDefault : 04C566AFF;
			clBtnHover : 088C0D0FF;
			clBtnPressed : 05E81ACFF;
			effect3d : 0;
		}
	}
}
