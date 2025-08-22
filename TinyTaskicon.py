from PIL import Image, ImageDraw, ImageFont

# Create blank 1024x1024 with transparent background
size = 1024
icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
draw = ImageDraw.Draw(icon)

# Draw circle background
draw.ellipse((0, 0, size, size), fill=(30, 144, 255, 255))  # DodgerBlue

# Draw white "▶" play symbol
font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 600)
text = "▶"
bbox = draw.textbbox((0, 0), text, font=font)
x = (size - (bbox[2] - bbox[0])) // 2
y = (size - (bbox[3] - bbox[1])) // 2
draw.text((x, y), text, font=font, fill=(255, 255, 255, 255))

# Save
icon.save("assets/icon.png")
print("Saved icon.png")
