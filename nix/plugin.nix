{ lib, vimUtils }:

vimUtils.buildVimPlugin {
  pname = "norg-diagram";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../lua
      ../plugin
      ../doc
    ];
  };

  nvimRequireCheck = "norg-diagram";

  meta = {
    description = "Neovim plugin for rendering various diagramming languages in norg with integrations";
    homepage = "https://github.com/DuckTapeMan35/norg-diagram";
    license = lib.licenses.gpl3;
  };
}
