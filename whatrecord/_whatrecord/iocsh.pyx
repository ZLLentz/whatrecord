# cython: language_level=3
import copy
import logging
import os
import pathlib
import traceback
import typing
from typing import Dict, List, Optional

from whatrecord.common import IocshResult, LoadContext

# cimport epicscorelibs
# cimport epicscorelibs.Com


logger = logging.getLogger(__name__)

def _get_redirect(redirects: dict, idx: int):
    if idx not in redirects:
        redirects[idx] = {"name": "", "mode": ""}
    return redirects[idx]


cdef class IOCShellLineParser:
    """
    Parsing helper for IOC shell lines.

    Note that this is almost a direct conversion of the original C code, making
    an attempt to avoid introducing inconsistencies between this implementation
    and the original.
    """
    # And (likely because of that?) this isn't very clean...
    num_redirects: int = 5
    ifs: bytes = b" \t(),\r"
    cdef public str string_encoding
    cdef public object macro_context

    def __init__(self, string_encoding: str = "latin-1", macro_context=None):
        self.string_encoding = string_encoding
        self.macro_context = macro_context

    cdef _decode_string(self, bytearr: bytearray):
        if 0 in bytearr:
            bytearr = bytearr[:bytearr.index(0)]
        return str(bytearr, self.string_encoding)

    cpdef split_words(self, input_line: str):
        """Split input_line into words, according to how the IOC shell would."""
        cdef int EOF = -1
        cdef int inword = 0
        cdef int quote = EOF
        cdef int backslash = 0
        cdef int idx = 0
        cdef int idx_out = 0
        cdef int redirectFd = 1
        cdef dict redirects = {}
        cdef char c
        redirect = None
        word_starts = []

        # TODO: read more:
        # https://cython.readthedocs.io/en/latest/src/tutorial/strings.html
        cdef bytearray line = bytearray(input_line.encode(self.string_encoding))
        # Add in a null terminator as we might need it
        line.append(0)

        while idx < len(line):
            c = line[idx]
            idx += 1

            if quote == EOF and not backslash and c in self.ifs:
                sep = 1
            else:
                sep = 0

            if quote == EOF and not backslash:
                if c == b'\\':
                    backslash = 1
                    continue
                if c == b'<':
                    if redirect:
                        break

                    redirect = _get_redirect(redirects, 0)
                    sep = 1
                    redirect["mode"] = "r"

                if b'1' <= c <= b'9' and line[idx] == b'>':
                    redirectFd = c - b'0'
                    c = b'>'
                    idx += 1

                if c == b'>':
                    if redirect:
                        break
                    if redirectFd >= self.num_redirects:
                        redirect = _get_redirect(redirects, 1)
                        break
                    redirect = _get_redirect(redirects, redirectFd)
                    sep = 1
                    if line[idx] == b'>':
                        idx += 1
                        redirect["mode"] = "a"
                    else:
                        redirect["mode"] = "w"

            if inword:
                if c == quote:
                    quote = EOF
                elif quote == EOF and not backslash:
                    if sep:
                        inword = 0
                        line[idx_out] = 0
                        idx_out += 1
                    elif c == b'"' or c == b"'":
                        quote = c
                    else:
                        line[idx_out] = c
                        idx_out += 1
                else:
                    line[idx_out] = c
                    idx_out += 1
            elif not sep:
                if (c == b'"' or c == b'\'') and not backslash:
                    quote = c
                if redirect:
                    if redirect["name"]:
                        break
                    redirect["name"] = idx_out
                    redirect = None
                else:
                    word_starts.append(idx_out)
                if quote == EOF:
                    line[idx_out] = c
                    idx_out += 1
                inword = 1
            backslash = 0

        if inword and idx_out < len(line):
            line[idx_out] = 0
            idx_out += 1

        # Python-only as we're not dealing with pointers to the string;
        # fix up redirect names by looking back at ``line``
        for _redir in redirects.values():
            if isinstance(_redir["name"], int):
                _redir["name"] = self._decode_string(line[_redir["name"]:])
            elif not _redir["name"]:
                error = f"Illegal redirection. ({_redir})"

        error = None

        if redirect is not None:
            error = f"Illegal redirection. ({redirect})"
        elif word_starts:
            if quote != EOF:
                error = f"Unbalanced quote. ({quote})"
            elif backslash:
                error = "Trailing backslash."

        return dict(
            # Python-only as we're not dealing with pointers to the string;
            # fix up argv words by looking back at the modified ``line``
            argv=[self._decode_string(line[word_start:]) for word_start in word_starts],
            redirects=redirects,
            error=error,
        )

    def parse(self, line: str, *, context: Optional[LoadContext] = None,
              prompt="epics>") -> IocshResult:
        """
        Parse an IOC shell line into an IocshResult.

        Parameters
        ----------
        line : str
            The line to parse.

        context : LoadContext, optional
            The load context to populate the result with.

        prompt : str, optional
            Replicating the EPICS source code, specify the state of the prompt
            here.  Defaults to "epics>".  If unset as in prior to IOC init,
            lines that do not start with "#-" will be eched.

        Returns
        -------
        IocshResult
            A partially filled IocshResult, ready for interpreting by a
            higher-level function.
        """
        result = IocshResult(
            context=context,
            line=line,
            outputs=[],
            argv=None,
            error=None,
            redirects={},
            result=None,
        )
        # Skip leading whitespace
        line = line.lstrip()

        if not line.startswith("#-"):
            result.outputs.append(line)

        if line.startswith('#'):
            # Echo non-empty lines read from a script.
            # Comments delineated with '#-' aren't echoed.
            return result

        if self.macro_context is not None:
            line = self.macro_context.expand(line)

         # * Skip leading white-space coming from a macro
        line = line.lstrip()

         # * Echo non-empty lines read from a script.
         # * Comments delineated with '#-' aren't echoed.
        if not prompt:
            if not line.startswith('#-'):
                result.outputs.append(line)

        # * Ignore lines that became a comment or empty after macro expansion
        if not line or line.startswith('#'):
            return result

        split = self.split_words(line)
        result.argv = split["argv"]
        result.redirects = split["redirects"]
        result.error = split["error"]
        return result