#include <antlr3.h>
#include <stdio.h>
#include <stdlib.h>

#include "SimpleLangLexer.h"
#include "SimpleLangParser.h"

static void parser_error_display(pANTLR3_BASE_RECOGNIZER recognizer,
                                 pANTLR3_UINT8* tokenNames) {
  recognizer->state->errorCount++;
  recognizer->displayRecognitionError(recognizer, tokenNames);
}

int main(int argc, char** argv) {
  const char* input_file = NULL;
  pANTLR3_INPUT_STREAM input = NULL;
  pSimpleLangLexer lexer = NULL;
  pANTLR3_COMMON_TOKEN_STREAM tokens = NULL;
  pSimpleLangParser parser = NULL;
  pANTLR3_BASE_RECOGNIZER base = NULL;
  SimpleLangParser_source_return r;

  if (argc < 2) {
    fprintf(stderr, "usage: parse_only_main <input-file>\n");
    return 1;
  }

  input_file = argv[1];
  input = antlr3FileStreamNew((pANTLR3_UINT8)input_file, ANTLR3_ENC_UTF8);
  if (!input) {
    fprintf(stderr, "Cannot open input file '%s'\n", input_file);
    return 1;
  }

  lexer = SimpleLangLexerNew(input);
  tokens =
      antlr3CommonTokenStreamSourceNew(ANTLR3_SIZE_HINT, TOKENSOURCE(lexer));
  parser = SimpleLangParserNew(tokens);
  base = (pANTLR3_BASE_RECOGNIZER)parser;
  base->displayRecognitionError = parser_error_display;

  r = parser->source(parser);
  if (base->state->errorCount > 0 || r.tree == NULL) {
    fprintf(stderr, "parse failed\n");
    parser->free(parser);
    tokens->free(tokens);
    lexer->free(lexer);
    input->close(input);
    return 2;
  }

  {
    pANTLR3_STRING tstr = r.tree->toStringTree(r.tree);
    fprintf(stderr, "parse ok, tree length=%u\n", (unsigned)tstr->len);
  }

  parser->free(parser);
  tokens->free(tokens);
  lexer->free(lexer);
  input->close(input);
  return 0;
}
