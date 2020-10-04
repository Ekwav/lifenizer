import { Component, OnInit } from '@angular/core';
import { SearchFieldDataSource, SearchFieldResult } from 'ngx-mat-search-field';
import { Observable } from 'rxjs';
import { ConversationService } from '../conversation.service';

@Component({
  selector: 'app-search',
  templateUrl: './search.component.html',
  styleUrls: ['./search.component.scss']
})
export class SearchComponent implements OnInit {

  searchFieldDataSource: SearchFieldDataSource;

  ngOnInit(): void {
  }

 
  constructor(private conversationService: ConversationService) {
    this.searchFieldDataSource = {
      search(search: string, size: number, skip: number): Observable<SearchFieldResult> {
        return conversationService.getConversations(search, size, skip);
      }
    };
  }

}
