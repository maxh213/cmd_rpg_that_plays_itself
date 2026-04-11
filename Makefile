SRCDIR = src
EBINDIR = ebin
SOURCES = $(wildcard $(SRCDIR)/*.erl)
BEAMS = $(SOURCES:$(SRCDIR)/%.erl=$(EBINDIR)/%.beam)

ERLC = erlc
ERLCFLAGS = -o $(EBINDIR) -I $(SRCDIR)

.PHONY: all run clean

all: $(BEAMS)

$(EBINDIR)/%.beam: $(SRCDIR)/%.erl | $(EBINDIR)
	$(ERLC) $(ERLCFLAGS) $<

$(EBINDIR):
	mkdir -p $(EBINDIR)

run: all
	erl -pa $(EBINDIR) -noshell -s rpg_app start

clean:
	rm -f $(EBINDIR)/*.beam
