import SwiftUI

/// Horizontal board pager for the Home feed.
///
/// Boards are pages of one native page controller rather than a hand-rolled
/// offset: while a swipe is in flight the neighbouring board is already mounted
/// and visible beside the current one, the transition is the platform curve, and
/// a release settles on a whole board. Vertical scrolling, refresh and paging
/// inside a page are untouched because every page is the same feed list.
struct ContentBoardPager<Page: View>: View {
    /// Ordered slugs, `""` being the combined feed. Must match the rail.
    let boards: [String]
    @Binding var selection: String
    @ViewBuilder let page: (String) -> Page

    var body: some View {
        TabView(selection: selectionBinding) {
            ForEach(boards, id: \.self) { board in
                page(board)
                    .tag(board)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    /// A saved board can disappear between launches; never hand the controller a
    /// selection it has no page for, or it silently shows the first page while
    /// the rail still highlights the missing one.
    private var selectionBinding: Binding<String> {
        Binding(get: { boards.contains(selection) ? selection : (boards.first ?? "") },
                set: { next in
                    guard boards.contains(next), next != selection else { return }
                    selection = next
                })
    }
}
