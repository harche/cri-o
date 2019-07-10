package enclib

import (
	"io"
)

type readerAtReader struct {
	r   io.ReaderAt
	off int64
}

// Takes an io.ReaderAt and returns an io.Reader
func ReaderFromReaderAt(r io.ReaderAt) io.Reader {
	return &readerAtReader{
		r:   r,
		off: 0,
	}
}

func (rar *readerAtReader) Read(p []byte) (n int, err error) {
	n, err = rar.r.ReadAt(p, rar.off)
	rar.off += int64(n)
	return n, err
}
