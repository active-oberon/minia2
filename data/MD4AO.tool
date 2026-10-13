Place cources in WORK/MD4AO/ directory
Compile:
Compiler.Compile MD4AO/MDTree.Mod MD4AO/MDInline.Mod MD4AO/MDParser.Mod MD4AO/MDSource.Mod MD4AO/MDSearch.Mod MD4AO/MDHighlight.Mod 
MD4AO/MDMath.Mod MD4AO/MDLayout.Mod MD4AO/MDConfig.Mod MD4AO/MDClip.Mod MD4AO/MDView.Mod ~

Look demo:
MDView.ShowArchive MD2AO-demo.zip ~
or
MDView.ShowArchive MD4AO/MD2AO-demo.zip ~

Unload from memory:
System.Free MDView MDClip MDConfig MDLayout MDSearch MDMath MDHighlight MDSource MDParser MDInline MDTree ~
