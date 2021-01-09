import { HttpClient } from '@angular/common/http';
import { AfterViewInit, Component, OnInit, ViewChild } from '@angular/core';
import { SearchFieldDataSource, SearchFieldResult } from 'ngx-mat-search-field';
import { Observable } from 'rxjs';
import { ConversationService } from '../conversation.service';

@Component({
  selector: 'app-search',
  templateUrl: './search.component.html',
  styleUrls: ['./search.component.scss']
})
export class SearchComponent implements OnInit,AfterViewInit {

  searchFieldDataSource: SearchFieldDataSource;
  @ViewChild('searchBar') searchBar;

  ngOnInit(): void {
    
  }

  ngAfterViewInit():void{
    console.log("after");
    this.searchBar.registerOnChange(console.log);
  }

 
  constructor(private conversationService: ConversationService, private httpClient : HttpClient) {
    this.searchFieldDataSource = {
      search(search: string, size: number, skip: number): Observable<SearchFieldResult> {
        return conversationService.getConversations(search, size, skip);
      }
    };
    httpClient.get("http://localhost:5000/test").subscribe();
  }

}
