{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "mermaid-ascii";
  version = "1.6.1";

  src = fetchFromGitHub {
    owner = "AlexanderGrooff";
    repo = "mermaid-ascii";
    tag = "1.6.1";
    hash = "sha256-KYCJIgLwjJR5RM1AdGrV47UhFgpLqwro42E54pzhYWE=";
  };

  vendorHash = "sha256-S/K6W8KC6YzwZPioucoiwOMd29LPv0J22T3MS0X+W5g=";

  meta = {
    description = "Render mermaid graphs inside your terminal";
    homepage = "https://github.com/AlexanderGrooff/mermaid-ascii";
    license = lib.licenses.mit;
    mainProgram = "mermaid-ascii";
  };
})
