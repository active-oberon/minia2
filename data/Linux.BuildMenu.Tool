MenuPages.Generate data/MenuPage00.XML Docu
	Tutorial "Notepad.Open Tutorial.Text"
~
MenuPages.Generate data/MenuPage10.XML System
	Configuration "PET.Open Configuration.XML"
	Log WMKernelLog.Open
	Macros "PET.Open Macros.XML"
	"Hot Keys" "PET.Open HotKeys.XML"
	Clock WMClock.Open
	Calendar WMCalendar.Open
	Installer WMInstaller.Open
	"Save Desktop" "WMRestorable.Store Auto.dsk;SkinEngine.SetCurrentAsDefault;StartMenu.ClosePopup"
	Reboot System.Reboot
	Shutdown System.PowerDown
~
MenuPages.Generate data/MenuPage20.XML Files
	Partitions WMPartitions.Open
	Files WMFileManager.Open
~
MenuPages.Generate data/MenuPage30.XML Tools
	Search WMSearchTool.Open
	Archiver WMArchives.Open
	Diff WMDiff.Open
	FTP WMFTPClient.Open
	"Serial Terminal" WMV24Component.Open
	"TCP Terminal" WMVT100.Start
	Shell WMShell.Open
	"Secure Shell" SSHTerminal.Open
~
MenuPages.Generate data/MenuPage40.XML Edit
	Text Notepad.Open
	DTP "DTPImage.Register;DTPRect.Register;DTPText.Register;DTPEditor.Open Demo"
	Styles "WMTextTool.Open;StartMenu.ClosePopup"
	"Input Methods" "WMInputMethodTool.Open;StartMenu.ClosePopup"
	"Unicode Markers" "WMUnicodeMarkerTool.Open;StartMenu.ClosePopup"
	"Unicode Map" WMCharMap.Open
	"Text Styles" "WMTextStyleTool.Open;StartMenu.ClosePopup"
~
MenuPages.Generate data/MenuPage50.XML Develop
	IDE PET.Open
	"GUI Builder" WMBuilder.Open
	"GUI Patterns" "Notepad.Open GUIPat.txt"
	Reset Reboot.Do
~
MenuPages.Generate data/MenuPage70.XML Inspect
	Performance WMPerfMon.Open
	Objects WMObjectTracker.Open
	Profiler WMProfiler.Open
	Events WMEventLog.Open
	Components WMInspector.Open
	Repositories WMRepositories.Open
~
MenuPages.Generate data/MenuPage90.XML Looks
	Backdrops "WMBackdropLoader.Open BackdropList.XML"
	"Skin Loader" "WMSkinLoader.Open SkinList.XML"
	"Skin Editor" SkinEditor.Open
	Language WMLanguageSwitcher.Open
~
