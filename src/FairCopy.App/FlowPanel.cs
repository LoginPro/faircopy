using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace FairCopy.App;

/// Перенос элементов по строкам (в WinUI нет WrapPanel): капсулы стилей.
sealed class FlowPanel : Panel
{
    public double Spacing { get; set; }
    public double LineSpacing { get; set; }

    protected override Size MeasureOverride(Size available) => Layout(available.Width, arrange: false);

    protected override Size ArrangeOverride(Size final)
    {
        Layout(final.Width, arrange: true);
        return final;
    }

    Size Layout(double maxWidth, bool arrange)
    {
        double x = 0, y = 0, lineHeight = 0, widest = 0;
        foreach (var child in Children)
        {
            if (!arrange) child.Measure(new Size(maxWidth, double.PositiveInfinity));
            var s = child.DesiredSize;
            if (x > 0 && x + s.Width > maxWidth)
            {
                y += lineHeight + LineSpacing;
                x = 0;
                lineHeight = 0;
            }
            if (arrange) child.Arrange(new Rect(x, y, s.Width, s.Height));
            x += s.Width + Spacing;
            widest = Math.Max(widest, x - Spacing);
            lineHeight = Math.Max(lineHeight, s.Height);
        }
        return new Size(double.IsInfinity(maxWidth) ? widest : maxWidth, y + lineHeight);
    }
}
