module ApplicationHelper
   def active_page(page, action)
    page.downcase == action.downcase ? "active" : ""
  end
end
