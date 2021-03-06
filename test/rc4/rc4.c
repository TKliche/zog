#include <stdio.h>
#include <string.h>
#include <stdlib.h>

unsigned char S[256];
unsigned int i, j;


void putnum(unsigned int num)
{
  char  buf[9];
  int   cnt;
  char  *ptr;
  int   digit;

  ptr = buf;
  for (cnt = 1 ; cnt >= 0 ; cnt--)
  {
    digit = (num >> (cnt * 4)) & 0xf;

    if (digit <= 9)
      *ptr++ = (char) ('0' + digit);
    else
      *ptr++ = (char) ('a' - 10 + digit);
  }

  *ptr = (char) 0;
  print (buf);
}

void swap(unsigned char *s, unsigned int i, unsigned int j)
{
    unsigned char temp = s[i];
    s[i] = s[j];
    s[j] = temp;
}


/* KSA */
void rc4_init(unsigned char *key, unsigned int key_length)
{
    for (i = 0; i < 256; i++)
    {
        S[i] = i;
    }
    for (i = j = 0; i < 256; i++)
    {
        j = (j + key[i % key_length] + S[i]) & 255;
        swap(S, i, j);
    }
    i = j = 0;
}


/* PRGA */
unsigned char rc4_output()
{
    i = (i + 1) & 255;
    j = (j + S[i]) & 255;
    swap(S, i, j);
    return S[(S[i] + S[j]) & 255];
}


int main()
{
    unsigned char* key = "Key";
    unsigned char* text = "Plaintext";

    print("RC4...\n");

    int x;
    int y;
    rc4_init(key, strlen(key));

    for (y = 0; y < strlen(text); y++)
    {
        putnum(text[y] ^ rc4_output());
        print(" ");
    }
    print("\n");

    print("Done.\n");

    return 0;
}
