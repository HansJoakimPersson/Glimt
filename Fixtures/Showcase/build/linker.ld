/* Load the image at 0x10000. */
ENTRY(_start)

SECTIONS
{
  . = 0x10000;
  .text : { *(.text) }
  .rodata : { *(.rodata*) }
  .data : { *(.data) }
  .bss : { *(.bss) }
}
