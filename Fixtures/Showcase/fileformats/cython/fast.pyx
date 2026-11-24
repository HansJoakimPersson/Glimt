# Pyrex/Cython
cdef int square(int x):
    return x * x

def total(int n):
    cdef int i, s = 0
    for i in range(n):
        s += square(i)
    return s
