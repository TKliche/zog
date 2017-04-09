#include <stdio.h>
#include <time.h>

#include "xxtea.h"

#ifdef __zpu__

#define printf iprintf
#define clock myclock
#define clock_t uint32_t

uint32_t clock()
{
    return *(uint32_t *)0x80000100;
}

static void
byteswap(uint32_t *ptr, size_t siz)
{
    uint32_t x;
    uint32_t y;

    while (siz > 0) {
        x = *ptr;
        y = (x >> 24) & 0xff;
        y |= (x >> 16) & 0xff00;
        y |= (x<<16) & 0xff0000;
        y |= (x<<24);
        *ptr = y;
        ptr++;
        siz -= 4;
    }
}

#endif

void btea(uint32_t *v, int n, uint32_t const k[4])
{
    uint32_t y, z, sum;
    unsigned p, rounds, e;
    if (n > 1)
    {                            /* Coding Part */
        rounds = 6 + 52/n;
        sum = 0;
        z = v[n-1];
        do
        {
            sum += DELTA;
            e = (sum >> 2) & 3;
            for (p=0; p<n-1; p++)
                y = v[p+1], z = v[p] += MX;
            y = v[0];
            z = v[n-1] += MX;
        } while (--rounds);
    }                            /* Decoding Part */
    else if (n < -1)
    {
        n = -n;
        rounds = 6 + 52/n;
        sum = rounds*DELTA;
        y = v[0];
        do
        {
            e = (sum >> 2) & 3;
            for (p=n-1; p>0; p--)
                z = v[p-1], y = v[p] -= MX;
            z = v[n-1];
            y = v[0] -= MX;
        } while ((sum -= DELTA) != 0);
    }
}


uint32_t testVector[] = {0x9d204ce7, 0xc03677f6, 0x320f0555, 0x499c703c,
                         0x8b8af399, 0x061b6314, 0x7d410085, 0xe65b712c,
                         0xb7d23609, 0x0270cd59, 0xa23dc8d1};

char key[16] = "0123456789ABCDEF";
int blockSize = sizeof(testVector) / 4;

int main(int argc, char* argv[])
{
    clock_t start, end;

#ifdef __zpu__NEVER
    byteswap(testVector, sizeof(testVector));
    byteswap(key, sizeof(key));
#endif
    start = clock();
    btea (testVector, -blockSize, (uint32_t*) key);
    end = clock();
#ifdef __zpu__NEVER
    byteswap(testVector, sizeof(testVector));
#endif
    printf("%s\n", (char*)testVector);
    printf("done in %lu cycles\n", (unsigned long)(end - start));

    return(0);
} 
